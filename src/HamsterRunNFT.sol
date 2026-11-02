// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Activity, GameMath, WeightClass } from "./GameMath.sol";
import { CoreReader } from "./CoreReader.sol";
import { ISqueekCore } from "./interfaces/ISqueekCore.sol";

interface IQueueBinding {
    function nft() external view returns (address);
}

/// @title HamsterRun — independent testnet pets, care, training and match locks.
/// @notice Free mints are wallet-limited, not person-limited. There is no ERC20 or promised yield.
contract HamsterRunNFT is ERC721, Ownable2Step, ReentrancyGuard, CoreReader {
    uint256 public constant MAX_SUPPLY = 9999;
    uint256 public constant START_STAMINA = 10;
    uint256 public constant FEED_SECONDS = 72 hours;
    uint64 public constant TRAIN_ROUNDS = 6;
    uint256 public constant STAMINA_PER_WORK = GameMath.STAMINA_PER_WORK;
    uint256 public constant MIN_TIER_BPS_GAP = 5000;
    uint256 public constant WEEKLY_MATCH_LIMIT = 5;
    uint256 public constant MAX_TRAIN_BPS = 50_000;
    /// @notice Training credit earned on low food never lifts the body score above this (Normal range).
    uint256 public constant LOW_FOOD_BODY_CEILING = 60;

    struct Hamster {
        uint256 stamina;
        uint256 fedUntil;
        uint256 trainBps;
        uint256 bodyScore;
        WeightClass weight;
        Activity activity;
        uint8 foodTier;
    }

    struct CareClock {
        uint256 bornAt;
        uint256 lastTrainAt;
        uint256 idleDaysApplied;
        uint256 hungerDaysApplied;
        /// @dev Booking time of the active Training lock; the inactivity clock is paused from here.
        uint256 trainBookedAt;
    }

    struct Training {
        uint64 trainStartRound;
        uint64 trainEndRound;
        uint256 lastFeedBps;
        uint8 tier;
    }

    struct TrainingStatus {
        bool active;
        uint64 trainStartRound;
        uint64 trainEndRound;
        uint64 frontier;
        bool ready;
        bool waitingForCertification;
        bool corePaused;
        uint64 work;
        uint256 gain;
    }

    struct Quota {
        uint256 week;
        uint256 used;
    }

    uint256 public totalSupply;
    bool public mintOpen;
    address public matchQueue;
    uint256[3] public foodPrices;
    uint256[3] public foodTrainBps;
    mapping(address => bool) public freeMinted;
    mapping(uint256 => Training) public training;
    mapping(uint256 => Quota) public matchQuota;
    mapping(uint256 => Hamster) internal _hamsters;
    mapping(uint256 => CareClock) private _careClocks;

    error MintClosed();
    error AlreadyMinted();
    error SoldOut();
    error NotTokenOwner();
    error Locked();
    error Hungry();
    error InvalidTier();
    error IncorrectPayment();
    error InvalidFoodConfig();
    error NoTraining();
    error QueueNotConfigured();
    error OnlyMatchQueue();
    error QueueAlreadyConfigured();
    error InvalidQueue();
    error WrongActivity();
    error WeeklyQuotaExceeded();
    error InvalidWithdrawal();
    error WithdrawalFailed();
    error OwnershipRequired();

    event MintOpenSet(bool open);
    event FoodConfigSet(uint256[3] prices, uint256[3] trainBps);
    event MatchQueueSet(address indexed queue);
    event HamsterMinted(uint256 indexed tokenId, address indexed player, bool free);
    event Fed(uint256 indexed tokenId, uint8 tier, uint256 fedUntil, uint256 trainBps, uint256 price);
    event BodyUpdated(uint256 indexed tokenId, uint256 bodyScore, WeightClass weight);
    event TrainingStarted(
        uint256 indexed tokenId, uint64 trainStartRound, uint64 trainEndRound, uint256 lastFeedBps
    );
    event TrainingSettled(uint256 indexed tokenId, uint64 certifiedWork, uint256 gain, uint256 stamina);
    event TrainingCancelled(uint256 indexed tokenId);
    event ActivityChanged(uint256 indexed tokenId, Activity activity);
    event MatchQuotaUsed(uint256 indexed tokenId, uint256 week, uint256 used);
    event MatchQuotaRefunded(uint256 indexed tokenId, uint256 week, uint256 used);
    event MatchRewarded(uint256 indexed tokenId, uint256 gain, uint256 stamina);
    event Withdrawn(address indexed recipient, uint256 amount);

    constructor(address initialOwner, address coreAddress)
        ERC721("hamsterrun", "HMR")
        Ownable(initialOwner)
        CoreReader(coreAddress)
    {
        foodPrices = [uint256(0.0001 ether), 0.0002 ether, 0.0003 ether];
        foodTrainBps = [uint256(10_000), 15_000, 20_000];
        emit FoodConfigSet(foodPrices, foodTrainBps);
    }

    modifier onlyMatchQueue() {
        if (matchQueue == address(0)) revert QueueNotConfigured();
        if (msg.sender != matchQueue) revert OnlyMatchQueue();
        _;
    }

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
        emit MintOpenSet(open);
    }

    /// @notice All tiers remain distinct in price and training benefit. Already-fed pets keep their bps.
    function setFoodConfig(uint256[3] calldata prices, uint256[3] calldata bps) external onlyOwner {
        if (
            prices[0] == 0 || prices[0] >= prices[1] || prices[1] >= prices[2] || bps[0] < 10_000
                || bps[0] >= bps[1] || bps[1] >= bps[2] || bps[2] > MAX_TRAIN_BPS
                || bps[1] - bps[0] < MIN_TIER_BPS_GAP || bps[2] - bps[1] < MIN_TIER_BPS_GAP
        ) revert InvalidFoodConfig();
        foodPrices = prices;
        foodTrainBps = bps;
        emit FoodConfigSet(prices, bps);
    }

    /// @notice One-time owner binding after both application contracts have been deployed.
    /// @dev No external call occurs in either application constructor.
    function setMatchQueue(address queue) external onlyOwner {
        if (matchQueue != address(0)) revert QueueAlreadyConfigured();
        if (queue == address(0) || queue.code.length == 0) revert InvalidQueue();
        if (IQueueBinding(queue).nft() != address(this)) revert InvalidQueue();
        matchQueue = queue;
        emit MatchQueueSet(queue);
    }

    function mint() external nonReentrant returns (uint256 tokenId) {
        if (!mintOpen) revert MintClosed();
        if (freeMinted[msg.sender]) revert AlreadyMinted();
        freeMinted[msg.sender] = true;
        tokenId = _mintHamster(msg.sender, true);
    }

    /// @notice Owner testing/distribution mint; shares the 9999 lifetime supply limit.
    function ownerMint(address player) external nonReentrant onlyOwner returns (uint256) {
        return _mintHamster(player, false);
    }

    /// @notice Allowed while Idle or Training: a booking keeps the food snapshot taken at its start, so
    ///         feeding during the (unbounded) certification wait only renews the 72h window and body care.
    function feed(uint256 tokenId, uint8 tier) external payable nonReentrant {
        _requireOwnerFeedable(tokenId);
        if (tier > 2) revert InvalidTier();
        if (msg.value != foodPrices[tier]) revert IncorrectPayment();
        _syncBody(tokenId);
        Hamster storage ham = _hamsters[tokenId];
        ham.fedUntil = block.timestamp + FEED_SECONDS;
        ham.foodTier = tier;
        ham.trainBps = foodTrainBps[tier];
        _careClocks[tokenId].hungerDaysApplied = 0;
        if (tier == 0) _damageBody(tokenId, 4);
        else _improveBody(tokenId, tier == 1 ? 6 : 12);
        emit Fed(tokenId, tier, ham.fedUntil, ham.trainBps, msg.value);
    }

    /// @notice Book six inclusive Core rounds starting in the current round. Must be fed and Idle.
    function startTraining(uint256 tokenId) external nonReentrant {
        _requireOwnerIdle(tokenId);
        _requireFed(tokenId);
        uint64 startRound = currentRound();
        if (startRound > type(uint64).max - (TRAIN_ROUNDS - 1)) revert RoundOverflow();
        uint64 endRound = startRound + TRAIN_ROUNDS - 1;
        Hamster storage ham = _hamsters[tokenId];
        _syncBody(tokenId);
        training[tokenId] = Training(startRound, endRound, ham.trainBps, ham.foodTier);
        // The certification wait is not idleness: the inactivity clock pauses here until the lock clears.
        _careClocks[tokenId].trainBookedAt = block.timestamp;
        _setActivity(tokenId, Activity.Training);
        emit TrainingStarted(tokenId, startRound, endRound, ham.trainBps);
    }

    /// @notice Anyone may settle earned work, including after feed expiry; only the NFT benefits.
    function settleTraining(uint256 tokenId) external nonReentrant {
        _requireOwned(tokenId);
        Training memory booked = training[tokenId];
        if (_hamsters[tokenId].activity != Activity.Training) revert NoTraining();
        uint64 work = certifiedWork(booked.trainStartRound, booked.trainEndRound);
        uint256 gain = GameMath.trainingGain(work, booked.lastFeedBps);
        _syncBody(tokenId);
        Hamster storage ham = _hamsters[tokenId];
        // Intentionally checked uint256 addition: no artificial stamina ceiling and no wraparound.
        ham.stamina += gain;
        // A certified zero-work window unlocks but cannot improve health or reset inactivity.
        if (work != 0) {
            uint256 gainCredit = gain > 10 ? 10 : gain;
            uint256 ceiling = booked.tier == 0 ? LOW_FOOD_BODY_CEILING : 100;
            _improveBody(tokenId, 2 + 2 * uint256(booked.tier) + gainCredit, ceiling);
            CareClock storage clock = _careClocks[tokenId];
            clock.lastTrainAt = block.timestamp;
            clock.idleDaysApplied = 0;
        } else {
            _resumeIdleClock(tokenId);
        }
        delete training[tokenId];
        _setActivity(tokenId, Activity.Idle);
        emit TrainingSettled(tokenId, work, gain, ham.stamina);
    }

    /// @notice An owner can always abandon training without a reward and feed/transfer again.
    function cancelTraining(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (_hamsters[tokenId].activity != Activity.Training) revert NoTraining();
        _syncBody(tokenId);
        _resumeIdleClock(tokenId);
        delete training[tokenId];
        _setActivity(tokenId, Activity.Idle);
        emit TrainingCancelled(tokenId);
    }

    function lockQueue(uint256 tokenId, address player) external nonReentrant onlyMatchQueue {
        if (ownerOf(tokenId) != player) revert NotTokenOwner();
        if (_hamsters[tokenId].activity != Activity.Idle) revert Locked();
        _requireFed(tokenId);
        if (matchesThisWeek(tokenId) >= WEEKLY_MATCH_LIMIT) revert WeeklyQuotaExceeded();
        _syncBody(tokenId);
        _setActivity(tokenId, Activity.Queued);
    }

    /// @notice The immutable queue snapshots stamina and effective weight here, at round lock.
    function lockMatch(uint256 tokenId)
        external
        nonReentrant
        onlyMatchQueue
        returns (address player, uint256 stamina, WeightClass weight)
    {
        player = ownerOf(tokenId);
        if (_hamsters[tokenId].activity != Activity.Queued) revert WrongActivity();
        _requireFed(tokenId);
        uint256 week = block.timestamp / 1 weeks;
        Quota storage quota = matchQuota[tokenId];
        if (quota.week != week) {
            quota.week = week;
            quota.used = 0;
        }
        if (quota.used >= WEEKLY_MATCH_LIMIT) revert WeeklyQuotaExceeded();
        ++quota.used;
        _syncBody(tokenId);
        _setActivity(tokenId, Activity.Matched);
        emit MatchQuotaUsed(tokenId, week, quota.used);
        Hamster storage ham = _hamsters[tokenId];
        return (player, ham.stamina, ham.weight);
    }

    function unlockQueue(uint256 tokenId) external nonReentrant onlyMatchQueue {
        _release(tokenId, Activity.Queued);
    }

    function expireMatchLock(uint256 tokenId) external nonReentrant onlyMatchQueue {
        _release(tokenId, Activity.Matched);
    }

    /// @notice The odd pet of a fulfilled round raced nobody: unlock it and hand back its weekly attempt.
    function releaseBye(uint256 tokenId) external nonReentrant onlyMatchQueue {
        _release(tokenId, Activity.Matched);
        Quota storage quota = matchQuota[tokenId];
        if (quota.used > 0) --quota.used;
        emit MatchQuotaRefunded(tokenId, quota.week, quota.used);
    }

    function rewardMatch(uint256 tokenId, bool won) external nonReentrant onlyMatchQueue {
        _requireOwned(tokenId);
        if (_hamsters[tokenId].activity != Activity.Matched) revert WrongActivity();
        uint256 gain = won ? 3 : 1;
        _hamsters[tokenId].stamina += gain;
        _release(tokenId, Activity.Matched);
        emit MatchRewarded(tokenId, gain, _hamsters[tokenId].stamina);
    }

    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0 || amount > address(this).balance) revert InvalidWithdrawal();
        address recipient = owner();
        emit Withdrawn(recipient, amount);
        (bool sent,) = payable(recipient).call{ value: amount }("");
        if (!sent) revert WithdrawalFailed();
    }

    /// @dev Keep fee withdrawal and administration recoverable through two-step ownership transfer.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    /// @notice Includes projected neglect since the last state touch, without requiring a transaction.
    function hamster(uint256 tokenId) public view returns (Hamster memory ham) {
        _requireOwned(tokenId);
        ham = _hamsters[tokenId];
        (ham.bodyScore,,) = _projectBody(tokenId);
        ham.weight = GameMath.weightClass(ham.bodyScore);
    }

    function isHungry(uint256 tokenId) public view returns (bool) {
        _requireOwned(tokenId);
        return _hamsters[tokenId].fedUntil == 0 || block.timestamp > _hamsters[tokenId].fedUntil;
    }

    function matchesThisWeek(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        Quota memory quota = matchQuota[tokenId];
        return quota.week == block.timestamp / 1 weeks ? quota.used : 0;
    }

    /// @notice Exact booked gain only after certification; unknown work is never represented as zero.
    function previewTrainingGain(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        if (_hamsters[tokenId].activity != Activity.Training) revert NoTraining();
        Training memory booked = training[tokenId];
        return GameMath.trainingGain(
            certifiedWork(booked.trainStartRound, booked.trainEndRound), booked.lastFeedBps
        );
    }

    /// @notice Readiness and frontier for clients. `work` and `gain` are known only when `ready` is true.
    function trainingStatus(uint256 tokenId) external view returns (TrainingStatus memory status) {
        _requireOwned(tokenId);
        status.active = _hamsters[tokenId].activity == Activity.Training;
        if (!status.active) return status;
        Training memory booked = training[tokenId];
        ISqueekCore.CoreState memory state = _coreState();
        status.trainStartRound = booked.trainStartRound;
        status.trainEndRound = booked.trainEndRound;
        status.frontier = state.settledThroughRound;
        status.ready = status.frontier >= booked.trainEndRound;
        status.waitingForCertification = !status.ready;
        status.corePaused = state.paused;
        if (status.ready) {
            status.work = _certifiedWork(booked.trainStartRound, booked.trainEndRound, status.frontier);
            status.gain = GameMath.trainingGain(status.work, booked.lastFeedBps);
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        Hamster memory ham = hamster(tokenId);
        string memory weight =
            ham.weight == WeightClass.Fit ? "Fit" : ham.weight == WeightClass.Normal ? "Normal" : "Obese";
        string memory json = string.concat(
            '{"name":"hamsterrun #',
            Strings.toString(tokenId),
            '","description":"Independent Sepolia testnet game. No promised rewards or yield.","attributes":[',
            '{"trait_type":"Stamina","value":',
            Strings.toString(ham.stamina),
            '},{"trait_type":"Weight","value":"',
            weight,
            '"},{"trait_type":"Body score","value":',
            Strings.toString(ham.bodyScore),
            '},{"trait_type":"Fed until","value":',
            Strings.toString(ham.fedUntil),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _mintHamster(address player, bool free) private returns (uint256 tokenId) {
        if (totalSupply >= MAX_SUPPLY) revert SoldOut();
        tokenId = ++totalSupply;
        _hamsters[tokenId] = Hamster(START_STAMINA, 0, 10_000, 50, WeightClass.Normal, Activity.Idle, 0);
        _careClocks[tokenId] = CareClock(block.timestamp, block.timestamp, 0, 0, 0);
        _safeMint(player, tokenId);
        emit HamsterMinted(tokenId, player, free);
    }

    function _requireOwnerIdle(uint256 tokenId) private view {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (_hamsters[tokenId].activity != Activity.Idle) revert Locked();
    }

    /// @dev Queue and match locks hold a stamina/weight snapshot that food must not disturb; a Training
    ///      lock holds only its own booking snapshot, which feed never touches.
    function _requireOwnerFeedable(uint256 tokenId) private view {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        Activity activity = _hamsters[tokenId].activity;
        if (activity != Activity.Idle && activity != Activity.Training) revert Locked();
    }

    function _requireFed(uint256 tokenId) private view {
        if (isHungry(tokenId)) revert Hungry();
    }

    function _setActivity(uint256 tokenId, Activity activity) private {
        _hamsters[tokenId].activity = activity;
        emit ActivityChanged(tokenId, activity);
    }

    function _release(uint256 tokenId, Activity expected) private {
        _requireOwned(tokenId);
        if (_hamsters[tokenId].activity != expected) revert WrongActivity();
        _syncBody(tokenId);
        _setActivity(tokenId, Activity.Idle);
    }

    function _projectBody(uint256 tokenId)
        private
        view
        returns (uint256 score, uint256 idleDays, uint256 hungerDays)
    {
        Hamster storage ham = _hamsters[tokenId];
        CareClock storage clock = _careClocks[tokenId];
        // Inactivity counts only outside a Training lock: a booked pet is waiting on Core, not idle.
        uint256 idleUntil = ham.activity == Activity.Training ? clock.trainBookedAt : block.timestamp;
        idleDays = (idleUntil - clock.lastTrainAt) / 1 days;
        // A never-fed newborn is hungry for gameplay gates, but its first feed window carries no damage.
        uint256 hungerStart = ham.fedUntil == 0 ? clock.bornAt + FEED_SECONDS : ham.fedUntil;
        if (block.timestamp > hungerStart) hungerDays = 1 + (block.timestamp - hungerStart - 1) / 1 days;
        uint256 damage = (idleDays - clock.idleDaysApplied) * 5 + (hungerDays - clock.hungerDaysApplied) * 5;
        score = damage >= ham.bodyScore ? 0 : ham.bodyScore - damage;
    }

    /// @dev Leaving Training without positive work (zero-work settle, cancel): the locked span is removed
    ///      from the inactivity clock so the wait is never billed, but the partial day in progress at booking
    ///      resumes where it paused. This is a pause, not the reset positive work earns. Call before the
    ///      activity changes, after `_syncBody` has applied every day completed up to the booking.
    function _resumeIdleClock(uint256 tokenId) private {
        CareClock storage clock = _careClocks[tokenId];
        clock.lastTrainAt += block.timestamp - clock.trainBookedAt;
    }

    function _syncBody(uint256 tokenId) private {
        (uint256 score, uint256 idleDays, uint256 hungerDays) = _projectBody(tokenId);
        CareClock storage clock = _careClocks[tokenId];
        clock.idleDaysApplied = idleDays;
        clock.hungerDaysApplied = hungerDays;
        _setBody(tokenId, score);
    }

    function _damageBody(uint256 tokenId, uint256 damage) private {
        uint256 score = _hamsters[tokenId].bodyScore;
        _setBody(tokenId, damage >= score ? 0 : score - damage);
    }

    function _improveBody(uint256 tokenId, uint256 gain) private {
        _improveBody(tokenId, gain, 100);
    }

    /// @dev Raises the score by `gain` but never above `ceiling`; a score already above it is left alone.
    function _improveBody(uint256 tokenId, uint256 gain, uint256 ceiling) private {
        uint256 score = _hamsters[tokenId].bodyScore;
        if (score >= ceiling) return;
        _setBody(tokenId, gain >= ceiling - score ? ceiling : score + gain);
    }

    function _setBody(uint256 tokenId, uint256 score) private {
        Hamster storage ham = _hamsters[tokenId];
        if (score == ham.bodyScore) return;
        ham.bodyScore = score;
        ham.weight = GameMath.weightClass(score);
        emit BodyUpdated(tokenId, score, ham.weight);
    }

    /// @dev All ERC721 transfer paths share this hook; approvals do not bypass gameplay locks.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) {
            if (_hamsters[tokenId].activity != Activity.Idle) revert Locked();
            _syncBody(tokenId);
        }
        return super._update(to, tokenId, auth);
    }
}
