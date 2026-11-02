// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { HamsterRunNFT } from "./HamsterRunNFT.sol";
import { GameMath, WeightClass } from "./GameMath.sol";
import { PointsLedger } from "./PointsLedger.sol";

/// @title HamsterRun random matchmaking and address points.
/// @notice Future-block randomness is suitable only for this non-financial testnet game.
/// @dev No owner, privileged keeper, caller-selected seed, wagering, or manual opponent selection.
contract MatchQueue is PointsLedger, ReentrancyGuard {
    uint256 public constant BAND_WIDTH = 25;
    uint256 public constant MAX_QUEUE_SIZE = 32;
    uint256 public constant QUEUE_TTL = 24 hours;
    /// @notice Blocks a pet must wait after enqueue before any round may lock it (about 2 minutes on Sepolia).
    uint256 public constant QUEUE_WAIT_BLOCKS = 10;
    uint256 public constant RANDOM_DELAY = 2;
    uint256 public constant RANDOM_WINDOW = 256;
    uint256 public constant WIN_POINTS = 10;
    uint256 public constant LOSS_POINTS = 2;

    enum RoundStatus {
        None,
        Pending,
        Fulfilled,
        Expired
    }

    struct Entry {
        uint256 tokenId;
        address player;
        uint256 joinedAt;
        uint256 joinedBlock;
    }

    struct Position {
        uint256 band;
        uint256 indexPlusOne;
    }

    struct Snapshot {
        uint256 tokenId;
        address player;
        uint256 stamina;
        WeightClass weight;
    }

    struct Round {
        uint256 band;
        uint256 entropyBlock;
        uint256 week;
        RoundStatus status;
        bytes32 seed;
        uint256 byeTokenId;
        Snapshot[] racers;
        uint256[] matchIds;
    }

    struct Race {
        uint256 roundId;
        Snapshot a;
        Snapshot b;
        uint256 scoreA;
        uint256 scoreB;
        uint256 winner;
        bool settled;
    }

    HamsterRunNFT public immutable nft;
    uint256 public roundCount;
    uint256 public matchCount;
    mapping(address => uint256) public activeToken;
    mapping(uint256 => Position) public position;
    mapping(uint256 => Entry[]) private _queues;
    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => Race) private _matches;

    error InvalidNFT();
    error NotTokenOwner();
    error PlayerAlreadyActive();
    error QueueFull();
    error NotQueued();
    error EntryStillLive();
    error NotEnoughPlayers();
    error InvalidRound();
    error RoundNotPending();
    error RandomnessNotReady();
    error RandomnessExpired();
    error RandomnessUnavailable();
    error RandomnessStillLive();
    error InvalidMatch();
    error MatchAlreadySettled();

    event Enqueued(uint256 indexed tokenId, address indexed player, uint256 indexed band);
    event LeftQueue(uint256 indexed tokenId, address indexed player, bool expired);
    event RoundLocked(uint256 indexed roundId, uint256 indexed band, uint256 entropyBlock, uint256 count);
    event RoundFulfilled(uint256 indexed roundId, bytes32 seed);
    event RoundBye(uint256 indexed roundId, uint256 indexed tokenId, address indexed player);
    event RoundExpired(uint256 indexed roundId);
    event MatchCreated(uint256 indexed matchId, uint256 indexed roundId, uint256 tokenA, uint256 tokenB);
    event MatchSettled(uint256 indexed matchId, uint256 indexed winner, uint256 scoreA, uint256 scoreB);

    /// @dev Address only: dependencies need not exist while the factory rehearses this constructor.
    constructor(address nftAddress) {
        if (nftAddress == address(0)) revert InvalidNFT();
        nft = HamsterRunNFT(nftAddress);
    }

    function enqueue(uint256 tokenId) external nonReentrant {
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (activeToken[msg.sender] != 0) revert PlayerAlreadyActive();
        uint256 band = bandOf(tokenId);
        if (_queues[band].length >= MAX_QUEUE_SIZE) revert QueueFull();
        activeToken[msg.sender] = tokenId;
        _queues[band].push(Entry(tokenId, msg.sender, block.timestamp, block.number));
        position[tokenId] = Position(band, _queues[band].length);
        emit Enqueued(tokenId, msg.sender, band);
        // NFT checks fed state, training/queue locks and quota. Failure rolls back all queue effects.
        nft.lockQueue(tokenId, msg.sender);
    }

    /// @notice Owner cancellation is possible only before a round commits its roster.
    function leaveQueue(uint256 tokenId) external nonReentrant {
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        Position memory pos = position[tokenId];
        if (pos.indexPlusOne == 0) revert NotQueued();
        Entry memory entry = _removeAt(pos.band, pos.indexPlusOne - 1);
        _unlockEntry(entry, false);
    }

    /// @notice Anyone can remove a hungry or stale waiting pet, freeing a full band's capacity.
    function evictExpired(uint256 tokenId) external nonReentrant {
        Position memory pos = position[tokenId];
        if (pos.indexPlusOne == 0) revert NotQueued();
        Entry memory entry = _queues[pos.band][pos.indexPlusOne - 1];
        if (!_expired(entry)) revert EntryStillLive();
        _removeAt(pos.band, pos.indexPlusOne - 1);
        _unlockEntry(entry, true);
    }

    /// @notice Lock every live pet in the band that has waited at least QUEUE_WAIT_BLOCKS (up to 32).
    /// @dev The caller selects only a band, never a subset: the whole eligible roster is committed, an
    ///      odd roster gets one entropy-chosen bye at fulfilment, and a pet enqueued in this block is not
    ///      eligible yet, so nobody can enter and lock in one transaction. Snapshots precede the entropy block.
    function requestRound(uint256 band) external nonReentrant returns (uint256 roundId) {
        _prune(band);
        Entry[] storage entries = _queues[band];
        uint256[] memory selected = new uint256[](entries.length);
        uint256 count;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (_eligible(entries[i])) selected[count++] = entries[i].tokenId;
        }
        if (count < 2) revert NotEnoughPlayers();
        roundId = ++roundCount;
        Round storage round = _rounds[roundId];
        round.band = band;
        round.entropyBlock = block.number + RANDOM_DELAY;
        round.week = block.timestamp / 1 weeks;
        round.status = RoundStatus.Pending;

        // IDs were captured before removal (removal swaps the last entry into the freed slot).
        for (uint256 i = 0; i < count; ++i) {
            uint256 tokenId = selected[i];
            _removeAt(band, position[tokenId].indexPlusOne - 1);
            (address player, uint256 stamina, WeightClass weight) = nft.lockMatch(tokenId);
            round.racers.push(Snapshot(tokenId, player, stamina, weight));
        }
        emit RoundLocked(roundId, band, round.entropyBlock, count);
    }

    /// @notice Shuffle the committed roster and create races using one predetermined future block.
    /// @dev Window is entropyBlock+1 through entropyBlock+256, inclusive. Caller/timestamp are not seeds.
    function fulfillRound(uint256 roundId) external nonReentrant {
        Round storage round = _pendingRound(roundId);
        if (block.number <= round.entropyBlock) revert RandomnessNotReady();
        if (block.number > round.entropyBlock + RANDOM_WINDOW) revert RandomnessExpired();
        bytes32 entropy = blockhash(round.entropyBlock);
        if (entropy == bytes32(0)) revert RandomnessUnavailable();
        bytes32 seed = keccak256(abi.encode(entropy, block.chainid, address(this), roundId));
        round.seed = seed;
        round.status = RoundStatus.Fulfilled;

        Snapshot[] memory shuffled = round.racers;
        for (uint256 i = shuffled.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, "PAIR", i))) % (i + 1);
            (shuffled[i], shuffled[j]) = (shuffled[j], shuffled[i]);
        }
        uint256 paired = shuffled.length - shuffled.length % 2;
        for (uint256 i = 0; i < paired; i += 2) {
            _createMatch(roundId, seed, i / 2, shuffled[i], shuffled[i + 1]);
        }
        emit RoundFulfilled(roundId, seed);
        if (paired < shuffled.length) {
            // The shuffle, not the caller, decides who sits out; the bye keeps its weekly attempt.
            Snapshot memory bye = shuffled[paired];
            round.byeTokenId = bye.tokenId;
            delete activeToken[bye.player];
            emit RoundBye(roundId, bye.tokenId, bye.player);
            nft.releaseBye(bye.tokenId);
        }
    }

    /// @notice If everyone misses the hash window, unlock with no reward; quota stays consumed.
    function expireRound(uint256 roundId) external nonReentrant {
        Round storage round = _pendingRound(roundId);
        if (block.number <= round.entropyBlock + RANDOM_WINDOW) revert RandomnessStillLive();
        round.status = RoundStatus.Expired;
        for (uint256 i = 0; i < round.racers.length; ++i) {
            Snapshot storage racer = round.racers[i];
            delete activeToken[racer.player];
            nft.expireMatchLock(racer.tokenId);
        }
        emit RoundExpired(roundId);
    }

    /// @notice Settlement is permissionless, has no deadline and uses only locked snapshots.
    function settleMatch(uint256 matchId) external nonReentrant {
        Race storage race = _matches[matchId];
        if (race.roundId == 0) revert InvalidMatch();
        if (race.settled) revert MatchAlreadySettled();
        race.settled = true;
        delete activeToken[race.a.player];
        delete activeToken[race.b.player];
        bool aWon = race.winner == race.a.tokenId;
        uint256 week = _rounds[race.roundId].week;
        _awardPoints(race.a.player, week, aWon ? WIN_POINTS : LOSS_POINTS);
        _awardPoints(race.b.player, week, aWon ? LOSS_POINTS : WIN_POINTS);
        emit MatchSettled(matchId, race.winner, race.scoreA, race.scoreB);
        // NFT has no receiver callbacks in rewardMatch. Failure rolls back points and both rewards.
        nft.rewardMatch(race.a.tokenId, aWon);
        nft.rewardMatch(race.b.tokenId, !aWon);
    }

    function bandOf(uint256 tokenId) public view returns (uint256) {
        return nft.hamster(tokenId).stamina / BAND_WIDTH;
    }

    function queueEntries(uint256 band) external view returns (Entry[] memory) {
        return _queues[band];
    }

    /// @notice Pets a `requestRound(band)` call would lock right now: live and past their wait window.
    function eligibleCount(uint256 band) external view returns (uint256 count) {
        Entry[] storage entries = _queues[band];
        for (uint256 i = 0; i < entries.length; ++i) {
            if (!_expired(entries[i]) && _eligible(entries[i])) ++count;
        }
    }

    /// @notice Token that sat out a fulfilled odd round, or 0 when every racer was paired.
    function roundBye(uint256 roundId) external view returns (uint256) {
        return _existingRound(roundId).byeTokenId;
    }

    function roundInfo(uint256 roundId)
        external
        view
        returns (
            uint256 band,
            uint256 entropyBlock,
            uint256 week,
            RoundStatus status,
            bytes32 seed,
            uint256 count
        )
    {
        Round storage round = _existingRound(roundId);
        return (round.band, round.entropyBlock, round.week, round.status, round.seed, round.racers.length);
    }

    function roundRacers(uint256 roundId) external view returns (Snapshot[] memory) {
        return _existingRound(roundId).racers;
    }

    function roundMatchIds(uint256 roundId) external view returns (uint256[] memory) {
        return _existingRound(roundId).matchIds;
    }

    function matchInfo(uint256 matchId) external view returns (Race memory) {
        if (_matches[matchId].roundId == 0) revert InvalidMatch();
        return _matches[matchId];
    }

    function previewRaceScore(uint256 stamina, WeightClass weight, uint256 noise)
        external
        pure
        returns (uint256)
    {
        return GameMath.raceScore(stamina, weight, noise);
    }

    function _createMatch(
        uint256 roundId,
        bytes32 seed,
        uint256 pairIndex,
        Snapshot memory a,
        Snapshot memory b
    ) private {
        uint256 matchId = ++matchCount;
        uint256 noiseA = uint256(keccak256(abi.encode(seed, "NOISE", pairIndex, a.tokenId))) % 2001;
        uint256 noiseB = uint256(keccak256(abi.encode(seed, "NOISE", pairIndex, b.tokenId))) % 2001;
        uint256 scoreA = GameMath.raceScore(a.stamina, a.weight, noiseA);
        uint256 scoreB = GameMath.raceScore(b.stamina, b.weight, noiseB);
        bool aWins = scoreA > scoreB
            || (scoreA == scoreB && uint256(keccak256(abi.encode(seed, "TIE", pairIndex))) % 2 == 0);
        _matches[matchId] = Race(roundId, a, b, scoreA, scoreB, aWins ? a.tokenId : b.tokenId, false);
        _rounds[roundId].matchIds.push(matchId);
        emit MatchCreated(matchId, roundId, a.tokenId, b.tokenId);
    }

    function _removeAt(uint256 band, uint256 index) private returns (Entry memory removed) {
        Entry[] storage entries = _queues[band];
        removed = entries[index];
        uint256 last = entries.length - 1;
        if (index != last) {
            entries[index] = entries[last];
            position[entries[index].tokenId].indexPlusOne = index + 1;
        }
        entries.pop();
        delete position[removed.tokenId];
    }

    function _unlockEntry(Entry memory entry, bool expired) private {
        delete activeToken[entry.player];
        emit LeftQueue(entry.tokenId, entry.player, expired);
        nft.unlockQueue(entry.tokenId);
    }

    function _expired(Entry memory entry) private view returns (bool) {
        return block.timestamp > entry.joinedAt + QUEUE_TTL || nft.isHungry(entry.tokenId);
    }

    function _eligible(Entry memory entry) private view returns (bool) {
        return block.number >= entry.joinedBlock + QUEUE_WAIT_BLOCKS;
    }

    function _prune(uint256 band) private {
        uint256 i = 0;
        while (i < _queues[band].length) {
            if (_expired(_queues[band][i])) {
                Entry memory entry = _removeAt(band, i);
                _unlockEntry(entry, true);
            } else {
                ++i;
            }
        }
    }

    function _existingRound(uint256 roundId) private view returns (Round storage) {
        Round storage round = _rounds[roundId];
        if (round.status == RoundStatus.None) revert InvalidRound();
        return round;
    }

    function _pendingRound(uint256 roundId) private view returns (Round storage) {
        Round storage round = _existingRound(roundId);
        if (round.status != RoundStatus.Pending) revert RoundNotPending();
        return round;
    }
}
