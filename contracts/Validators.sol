pragma solidity >=0.6.0 <0.8.0;

import "./Params.sol";
import "./Proposal.sol";
import "./Punish.sol";
import "./library/SafeMath.sol";
import "./HSCTToken.sol";

contract Validators is Params {
    using SafeMath for uint256;

    enum Status {
        // validator not exist, default status
        NotExist,
        // validator has staked coins
        Staked,
        // validator reclaim his staking coin back but not finished.
        Unstaking,
        // validator has withdraw his staking back.
        Unstaked,
        // validator is jailed by system for too much miss
        Jailed
    }

    struct Description {
        string moniker;
        string identity;
        string website;
        string email;
        string details;
    }

    struct Validator {
        address payable valAddr;
        address payable feeAddr;
        Status status;
        uint256 coins;
        Description description;
        uint256 removedBlock;
        uint256 hbIncoming;
        uint256 hsctIncoming;
        uint256 totalJailedHB;
        uint256 totalJailedHSCT;
        uint256 lastWithdrawProfitsBlock;
    }

    struct Dec {
        uint256 multi;
        uint256 divisor;
    }

    mapping(address => Validator) validatorInfo;
    // store current validator set used by chain
    // only changed at block epoch
    address[] public currentValidatorSet;
    // store highest validator set(sort by staking, dynamic changed)
    address[] public highestValidatorsSet;
    // calculate block profit
    Dec dec;
    // admin
    address public admin;

    // System contracts
    Proposal proposal;
    HSCTToken hsctToken;
    Punish punish;

    enum Operations {Deposit, UpdateValidators}
    // Record the operations is done or not.
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

    event LogCreateValidator(
        address indexed val,
        address indexed fee,
        uint256 staking,
        uint256 time
    );
    event LogEditValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogAddToTopValidators(address indexed val, uint256 time);
    event LogRemoveFromTopValidators(address indexed val, uint256 time);
    event LogUnstake(address indexed val, uint256 time);
    event LogWithdrawStaking(address indexed val, uint256 amount, uint256 time);
    event LogWithdrawProfits(
        address indexed val,
        address indexed fee,
        uint256 hb,
        uint256 hsct,
        uint256 time
    );
    event LogRemoveValidator(
        address indexed val,
        uint256 hb,
        uint256 hsct,
        uint256 time
    );
    event LogRemoveValidatorIncoming(
        address indexed val,
        uint256 hb,
        uint256 hsct,
        uint256 time
    );
    event LogDepositBlockReward(
        address indexed val,
        uint256 hb,
        uint256 hsct,
        uint256 time
    );
    event LogUpdateValidator(address[] newSet);
    event LogAddStake(address indexed val, uint256 addAmount, uint256 time);
    event LogRestake(address indexed val, uint256 restake, uint256 time);
    event LogChangeDec(uint256 newMulti, uint256 newDivisor, uint256 time);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Admin only");
        _;
    }

    modifier onlyNotReward() {
        require(
            operationsDone[block.number][uint8(Operations.Deposit)] == false,
            "Block is already rewarded"
        );
        _;
    }

    modifier onlyNotUpdate() {
        require(
            operationsDone[block.number][uint8(Operations.UpdateValidators)] ==
                false,
            "Validators already updated"
        );
        _;
    }

    function initialize(address[] calldata vals, address admin_)
        external
        onlyNotInitialized
    {
        proposal = Proposal(ProposalAddr);
        hsctToken = HSCTToken(HsctTokenAddr);
        punish = Punish(PunishContractAddr);
        dec.multi = 100;
        dec.divisor = 100;
        require(admin_ != address(0), "Invalid admin address");
        admin = admin_;

        for (uint256 i = 0; i < vals.length; i++) {
            require(vals[i] != address(0), "Invalid validator address");

            if (!isActiveValidator(vals[i])) {
                currentValidatorSet.push(vals[i]);
            }
            if (!isTopValidator(vals[i])) {
                highestValidatorsSet.push(vals[i]);
            }
            if (validatorInfo[vals[i]].valAddr == address(0)) {
                validatorInfo[vals[i]].valAddr = payable(vals[i]);
            }
            if (validatorInfo[vals[i]].feeAddr == address(0)) {
                validatorInfo[vals[i]].feeAddr = payable(vals[i]);
            }
            // Important: NotExist validator can't get profits
            if (validatorInfo[vals[i]].status == Status.NotExist) {
                validatorInfo[vals[i]].status = Status.Staked;
            }
        }

        initialized = true;
    }

    function changeDec(uint256 multi_, uint256 divisor_)
        public
        onlyInitialized
        onlyAdmin
    {
        require(divisor_ != 0, "Invalid divisor");
        dec.multi = multi_;
        dec.divisor = divisor_;

        emit LogChangeDec(multi_, divisor_, block.timestamp);
    }

    // first time stake or add stake
    function stake(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external payable onlyInitialized returns (bool) {
        address payable validator = msg.sender;
        uint256 staking = msg.value;

        require(proposal.pass(validator), "You must be authorized first");

        // stake at first time
        if (validatorInfo[validator].status == Status.NotExist) {
            require(feeAddr != address(0), "Invalid fee address");
            require(staking >= MinimalStakingCoin, "Staking coins not enough");
            require(
                validateDescription(moniker, identity, website, email, details),
                "Invalid description"
            );

            Validator memory val;
            val.valAddr = validator;
            val.feeAddr = feeAddr;
            val.status = Status.Staked;
            val.coins = staking;
            val.description = Description(
                moniker,
                identity,
                website,
                email,
                details
            );

            validatorInfo[validator] = val;

            tryAddValidatorToHighestSet(validator, staking);

            emit LogCreateValidator(
                validator,
                feeAddr,
                staking,
                block.timestamp
            );
            return true;
        }

        // restake if you are unstaked
        // just update stake coin info
        if (validatorInfo[validator].status == Status.Unstaked) {
            require(staking >= MinimalStakingCoin, "Staking coins not enough");
            require(punish.cleanPunishRecord(validator), "clean failed");

            validatorInfo[validator].coins = staking;
            validatorInfo[validator].status = Status.Staked;
            tryAddValidatorToHighestSet(validator, staking);

            emit LogRestake(validator, staking, block.timestamp);
            return true;
        }

        // add stake
        require(
            validatorInfo[validator].status == Status.Staked,
            "You can only add stake when staked"
        );
        validatorInfo[validator].coins = validatorInfo[validator].coins.add(
            msg.value
        );
        tryAddValidatorToHighestSet(validator, validatorInfo[validator].coins);

        emit LogAddStake(msg.sender, msg.value, block.timestamp);
    }

    function editValidator(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external onlyInitialized returns (bool) {
        require(
            validatorInfo[msg.sender].status != Status.NotExist,
            "Validator not exist"
        );
        require(feeAddr != address(0), "Invalid fee address");
        require(
            validateDescription(moniker, identity, website, email, details),
            "Invalid description"
        );

        validatorInfo[msg.sender].feeAddr = feeAddr;
        validatorInfo[msg.sender].description = Description(
            moniker,
            identity,
            website,
            email,
            details
        );

        emit LogEditValidator(msg.sender, feeAddr, block.timestamp);
        return true;
    }

    function unstake() external onlyInitialized returns (bool) {
        address validator = msg.sender;
        require(
            validatorInfo[validator].status == Status.Staked,
            "Invalid status, can't unstake"
        );
        // If you are the only one top validator, then you can't unstake
        // You can unstake if you are not top validator.
        // Or top validators length > 1.
        require(
            highestValidatorsSet.length > 1 || !isTopValidator(validator),
            "You are the only one validator, can't unstake!"
        );

        validatorInfo[validator].status = Status.Unstaking;
        validatorInfo[validator].removedBlock = block.number;

        // try to remove it out of active validator set if exist.
        tryRemoveValidatorInHighestSet(validator);

        // call proposal contract to set unpass.
        // you have to repropose to be a validator.
        proposal.setUnpassed(validator);
        emit LogUnstake(validator, block.timestamp);
        return true;
    }

    function withdrawStaking() external returns (bool) {
        address payable validator = payable(msg.sender);
        // unstaking or jailed.
        require(
            validatorInfo[validator].status != Status.NotExist &&
                validatorInfo[validator].status != Status.Staked,
            "validator not exist or staked"
        );

        // Ensure validator can withdraw his staking back
        require(
            validatorInfo[validator].removedBlock + StakingLockPeriod <=
                block.number,
            "Your staking haven't unlocked yet"
        );

        uint256 staking = validatorInfo[validator].coins;
        validatorInfo[validator].coins = 0;
        // set status to unstaked no matter you are jailed/unstaking.
        // you can stake if you repass proposal.
        validatorInfo[validator].status = Status.Unstaked;
        // send stake back to origin validator.
        safeTransferHB(validator, staking);

        emit LogWithdrawStaking(validator, staking, block.timestamp);

        return true;
    }

    // feeAddr can withdraw profits of it's validator
    function withdrawProfits(address validator) external returns (bool) {
        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );
        require(
            validatorInfo[validator].feeAddr == msg.sender,
            "You are not the fee receiver of this validator"
        );
        require(
            validatorInfo[validator].lastWithdrawProfitsBlock +
                WithdrawProfitPeriod <=
                block.number,
            "You must wait enough to withdraw you profits after latest withdraw of this validator"
        );

        uint256 hbIncoming = validatorInfo[validator].hbIncoming;
        uint256 hsctIncoming = validatorInfo[validator].hsctIncoming;

        // update info
        validatorInfo[validator].hbIncoming = 0;
        validatorInfo[validator].hsctIncoming = 0;
        validatorInfo[validator].lastWithdrawProfitsBlock = block.number;

        // send profits to fee address
        if (hbIncoming > 0) {
            safeTransferHB(msg.sender, hbIncoming);
        }

        if (hsctIncoming > 0) {
            safeTransferHSCT(msg.sender, hsctIncoming);
        }

        emit LogWithdrawProfits(
            validator,
            msg.sender,
            hbIncoming,
            hsctIncoming,
            block.timestamp
        );

        return true;
    }

    // depositBlockReward block reward and gas fee to coin base
    function depositBlockReward()
        external
        payable
        onlyMiner
        onlyNotReward
        onlyInitialized
    {
        operationsDone[block.number][uint8(Operations.Deposit)] = true;
        address val = msg.sender;
        uint256 hsct = msg.value;

        // never reach this
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }

        validatorInfo[val].hbIncoming = validatorInfo[val].hbIncoming.add(
            msg.value
        );

        // calculate actual hsct profit
        uint256 hsctMint = hsct.mul(dec.multi).div(dec.divisor);
        // mint hsct token for this contract
        hsctMint = hsctToken.mint(address(this), hsctMint);

        validatorInfo[val].hsctIncoming = validatorInfo[val].hsctIncoming.add(
            hsctMint
        );
        // mint token for this contract, then validator can withdraw it
        if (validatorInfo[val].status == Status.Jailed) {
            tryRemoveValidatorIncoming(val);
        }

        emit LogDepositBlockReward(val, msg.value, hsctMint, block.timestamp);
    }

    function updateActiveValidatorSet(address[] memory newSet, uint256 epoch)
        public
        onlyMiner
        onlyNotUpdate
        onlyInitialized
        onlyBlockEpoch(epoch)
    {
        operationsDone[block.number][uint8(Operations.UpdateValidators)] = true;
        require(newSet.length > 0, "Validator set empty!");

        // TODO: optimize
        uint256 l = currentValidatorSet.length;
        for (uint256 i = 0; i < l; i++) {
            currentValidatorSet.pop();
        }

        for (uint256 i = 0; i < newSet.length; i++) {
            currentValidatorSet.push(newSet[i]);
        }

        emit LogUpdateValidator(newSet);
    }

    function removeValidator(address val) external onlyPunishContract {
        uint256 hb = validatorInfo[val].hbIncoming;
        uint256 hsct = validatorInfo[val].hsctIncoming;

        tryRemoveValidatorIncoming(val);

        // remove the validator out of active set
        // Note: the jailed validator may in active set if there is only one validator exists
        if (highestValidatorsSet.length > 1) {
            tryJailValidator(val);

            // call proposal contract to set unpass.
            // you have to repropose to be a validator.
            proposal.setUnpassed(val);
            emit LogRemoveValidator(val, hb, hsct, block.timestamp);
        }
    }

    function removeValidatorIncoming(address val) external onlyPunishContract {
        tryRemoveValidatorIncoming(val);
    }

    function getValidatorDescription(address val)
        public
        view
        returns (
            string memory,
            string memory,
            string memory,
            string memory,
            string memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (
            v.description.moniker,
            v.description.identity,
            v.description.website,
            v.description.email,
            v.description.details
        );
    }

    function getValidatorInfo(address val)
        public
        view
        returns (
            address payable,
            Status,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        Validator memory v = validatorInfo[val];

        return (
            v.feeAddr,
            v.status,
            v.coins,
            v.removedBlock,
            v.hbIncoming,
            v.hsctIncoming,
            v.totalJailedHB,
            v.totalJailedHSCT,
            v.lastWithdrawProfitsBlock
        );
    }

    function getActiveValidators() public view returns (address[] memory) {
        address[] memory activeSet = new address[](currentValidatorSet.length);

        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            activeSet[i] = currentValidatorSet[i];
        }
        return activeSet;
    }

    function isActiveValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (currentValidatorSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function isTopValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function getTopValidators() public view returns (address[] memory) {
        address[] memory topSet = new address[](highestValidatorsSet.length);

        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            topSet[i] = highestValidatorsSet[i];
        }
        return topSet;
    }

    function validateDescription(
        string memory moniker,
        string memory identity,
        string memory website,
        string memory email,
        string memory details
    ) public pure returns (bool) {
        require(bytes(moniker).length <= 70, "Invalid moniker length");
        require(bytes(identity).length <= 3000, "Invalid identity length");
        require(bytes(website).length <= 140, "Invalid website length");
        require(bytes(email).length <= 140, "Invalid email length");
        require(bytes(details).length <= 280, "Invalid details length");

        return true;
    }

    function tryAddValidatorToHighestSet(address val, uint256 staking)
        internal
    {
        // do nothing if you are already in highestValidatorsSet set
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == val) {
                return;
            }
        }

        if (highestValidatorsSet.length < MaxValidators) {
            highestValidatorsSet.push(val);
            return;
        }

        // find lowest validator index in current validator set
        uint256 lowest = validatorInfo[highestValidatorsSet[0]].coins;
        uint256 lowestIndex = 0;
        for (uint256 i = 1; i < highestValidatorsSet.length; i++) {
            if (validatorInfo[highestValidatorsSet[i]].coins < lowest) {
                lowest = validatorInfo[highestValidatorsSet[i]].coins;
                lowestIndex = i;
            }
        }

        // do nothing if staking amount isn't bigger than current lowest
        if (staking <= lowest) {
            return;
        }

        // replace the lowest validator
        emit LogAddToTopValidators(val, block.timestamp);
        emit LogRemoveFromTopValidators(
            highestValidatorsSet[lowestIndex],
            block.timestamp
        );
        highestValidatorsSet[lowestIndex] = val;
    }

    function tryRemoveValidatorIncoming(address val) private {
        // do nothing if validator not exist(impossible)
        if (
            validatorInfo[val].status == Status.NotExist ||
            currentValidatorSet.length <= 1
        ) {
            return;
        }
        uint256 luckHBIncoming = validatorInfo[val].hbIncoming.div(
            currentValidatorSet.length - 1
        );
        uint256 luckHSCTIncoming = validatorInfo[val].hsctIncoming.div(
            currentValidatorSet.length - 1
        );

        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (val != currentValidatorSet[i]) {
                validatorInfo[currentValidatorSet[i]]
                    .hbIncoming = luckHBIncoming.add(
                    validatorInfo[currentValidatorSet[i]].hbIncoming
                );
                validatorInfo[currentValidatorSet[i]]
                    .hsctIncoming = luckHSCTIncoming.add(
                    validatorInfo[currentValidatorSet[i]].hsctIncoming
                );
            }
        }

        uint256 hb = validatorInfo[val].hbIncoming;
        uint256 hsct = validatorInfo[val].hsctIncoming;
        validatorInfo[val].totalJailedHB = validatorInfo[val].totalJailedHB.add(
            validatorInfo[val].hbIncoming
        );
        validatorInfo[val].totalJailedHSCT = validatorInfo[val]
            .totalJailedHSCT
            .add(validatorInfo[val].hsctIncoming);

        validatorInfo[val].hbIncoming = 0;
        validatorInfo[val].hsctIncoming = 0;

        emit LogRemoveValidatorIncoming(val, hb, hsct, block.timestamp);
    }

    function tryJailValidator(address val) private {
        // do nothing if validator not exist
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }

        // set validator status to jailed
        validatorInfo[val].status = Status.Jailed;
        // set validator jailed block, so it can withdraw his staking after lock time.
        validatorInfo[val].removedBlock = block.number;

        // try to remove if it's in active validator set
        tryRemoveValidatorInHighestSet(val);
    }

    function tryRemoveValidatorInHighestSet(address val) private {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (val == highestValidatorsSet[i]) {
                // remove it
                if (i != highestValidatorsSet.length - 1) {
                    highestValidatorsSet[i] = highestValidatorsSet[highestValidatorsSet
                        .length - 1];
                }

                highestValidatorsSet.pop();
                emit LogRemoveFromTopValidators(val, block.timestamp);

                break;
            }
        }
    }

    function safeTransferHB(address payable to, uint256 amount) internal {
        if (amount > address(this).balance) {
            amount = address(this).balance;
        }
        to.transfer(amount);
    }

    function safeTransferHSCT(address to, uint256 amount) internal {
        if (amount > hsctToken.balanceOf(address(this))) {
            amount = hsctToken.balanceOf(address(this));
        }

        hsctToken.transfer(to, amount);
    }
}