pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {ReentrancyGuard} from "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import {CErc20Interface} from '../compound/contracts/CErc20Interface.sol';
import {IERC20, IRToken} from "./IRToken.sol";

contract RToken is IRToken, ReentrancyGuard {

    using SafeMath for uint256;

    uint256 public constant SELF_HAT_ID = uint256(int256(-1));

    uint32 constant PROPORTION_BASE = 0xFFFFFFFF;

    //
    // public structures
    //

    /**
     * @notice Hat structure describes who are the recipients of the interest
     *
     * To be a valid hat structure:
     *   - at least one recipient
     *   - recipients.length == proportions.length
     *   - each value in proportions should be greater than 0
     */
    struct Hat {
        address[] recipients;
        uint32[] proportions;
    }

    /**
     * @notice Create rToken linked with cToken at `cToken_`
     */
    constructor (CErc20Interface cToken_) public {
        cToken = cToken_;
        // special hat aka. zero hat : hatID = 0
        hats.push(Hat(new address[](0), new uint32[](0)));
    }

    //
    // ERC20 Interface
    //

    /**
     * @notice EIP-20 token name for this token
     */
    string public name = "Redeemable DAI (rDAI)";

    /**
     * @notice EIP-20 token symbol for this token
     */
    string public symbol = "rDAI";

    /**
     * @notice EIP-20 token decimals for this token
     */
    uint256 public decimals = 18;

     /**
      * @notice Total number of tokens in circulation
      */
     uint256 public totalSupply;

    /**
     * @notice Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address owner) external view returns (uint256) {
        return accounts[owner].rAmount;
    }

    /**
     * @notice Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     */
    function transfer(address dst, uint256 amount) external nonReentrant returns (bool) {
        return transferInternal(msg.sender, msg.sender, dst, amount);
    }

    /**
     * @notice Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through `transferFrom`. This is
     * zero by default.
     *
     * This value changes when `approve` or `transferFrom` are called.
     */
    function allowance(address owner, address spender) external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * > Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an `Approval` event.
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    /**
     * @notice Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     */
    function transferFrom(address src, address dst, uint256 amount) external nonReentrant returns (bool) {
        return transferInternal(msg.sender, src, dst, amount);
    }

    //
    // rToken interface
    //

    /// @dev mint implementation
    function mint(uint256 mintAmount) external nonReentrant returns (bool) {
        mintInternal(mintAmount);
        return true;
    }

    /// @dev mintWithSelectedHat implementation
    function mintWithSelectedHat(uint256 mintAmount, uint256 hatID) external returns (bool) {
        require(hatID == SELF_HAT_ID || hatID < hats.length, "Invalid hat ID");
        changeHatInternal(msg.sender, hatID);
        mintInternal(mintAmount);
        return true;
    }

    /**
     * @dev mintWithNewHat implementation
     */
    function mintWithNewHat(uint256 mintAmount,
        address[] calldata recipients,
        uint32[] calldata proportions) external nonReentrant returns (bool) {
        uint256 hatID = createHatInternal(recipients, proportions);
        changeHatInternal(msg.sender, hatID);

        mintInternal(mintAmount);

        return true;
    }

    /**
     * @dev redeem implementation
     *      It withdraws equal amount of initially supplied underlying assets
     */
    function redeem(uint256 redeemTokens) external nonReentrant returns (bool) {
        redeemInternal(redeemTokens);
        return true;
    }

     /// @dev createHat implementation
    function createHat(
        address[] calldata recipients,
        uint32[] calldata proportions,
        bool doChangeHat) external nonReentrant returns (uint256 hatID) {
        hatID = createHatInternal(recipients, proportions);
        if (doChangeHat) {
            changeHatInternal(msg.sender, hatID);
        }
    }

    /// @dev changeHat implementation
    function changeHat(uint256 hatID) external nonReentrant {
        changeHatInternal(msg.sender, hatID);
    }

    /// @dev getMaximumHatID implementation
    function getMaximumHatID() external view returns (uint256 hatID) {
        return hats.length - 1;
    }

    /// @dev getHatByAddress implementation
    function getHatByAddress(address owner) external view returns (
        uint256 hatID,
        address[] memory recipients,
        uint32[] memory proportions) {
        hatID = accounts[owner].hatID;
        if (hatID != 0 && hatID != SELF_HAT_ID) {
            Hat memory hat = hats[hatID];
            recipients = hat.recipients;
            proportions = hat.proportions;
        } else {
            recipients = new address[](0);
            proportions = new uint32[](0);
        }
    }

    /// @dev getHatByID implementation
    function getHatByID(uint256 hatID) external view returns (
        address[] memory recipients,
        uint32[] memory proportions) {
        if (hatID != 0 && hatID != SELF_HAT_ID) {
            Hat memory hat = hats[hatID];
            recipients = hat.recipients;
            proportions = hat.proportions;
        } else {
            recipients = new address[](0);
            proportions = new uint32[](0);
        }
    }

    /// @dev receivedSavingsOf implementation
    function receivedSavingsOf(address owner) external view returns (uint256 amount) {
        Account storage account = accounts[owner];
        uint256 rGross = account.sAmount
            .mul(cToken.exchangeRateStored())
            .div(10 ** 18);
        return rGross;
    }

    /// @dev receivedLoanOf implementation
    function receivedLoanOf(address owner) external view returns (uint256 amount) {
        Account storage account = accounts[owner];
        return account.lDebt;
    }

    /// @dev interestPayableOf implementation
    function interestPayableOf(address owner) external view returns (uint256 amount) {
        Account storage account = accounts[owner];
        return getInterestPayableOf(account);
    }

    /// @dev payInterest implementation
    function payInterest(address owner) external nonReentrant returns (bool) {
        Account storage account = accounts[owner];

        cToken.accrueInterest();
        uint256 interestAmount = getInterestPayableOf(account);

        if (interestAmount > 0) {
            account.stats.cumulativeInterest = account.stats.cumulativeInterest.add(interestAmount);
            account.rInterest = account.rInterest.add(interestAmount);
            account.rAmount = account.rAmount.add(interestAmount);
            totalSupply = totalSupply.add(interestAmount);
            emit InterestPaid(owner, interestAmount);
            emit Transfer(address(this), owner, interestAmount);
        }
    }

    /// @dev getAccountStats implementation!1
    function getGlobalStats() external view returns (GlobalStats memory) {
        uint256 totalSavingsAmount;
        totalSavingsAmount += savingAssets[address(0)]
            .mul(cToken.exchangeRateStored())
            .div(10 ** 18);
        return GlobalStats({
            totalSupply: totalSupply,
            totalSavingsAmount: totalSavingsAmount
        });
    }

    /// @dev getAccountStats implementation
    function getAccountStats(address owner) external view returns (AccountStats memory) {
        Account storage account = accounts[owner];
        return account.stats;
    }

    /// @dev getCurrentSavingStrategy implementation
    function getCurrentSavingStrategy() external view returns (address) {
        return ss;
    }

    /// @dev getSavingAssetBalance implementation
    function getSavingAssetBalance(address strategy) external view
        returns (uint256 nAmount, uint256 sAmount) {
        sAmount = savingAssets[strategy];
        nAmount = sAmount
            .mul(cToken.exchangeRateStored())
            .div(10 ** 18);
    }

    //
    // internal
    //

    /// @dev Current saving strategy contract
    address ss = address(0);

    /// @dev Compound token associated with the rToken
    CErc20Interface cToken;

    /// @dev Saving assets indexed by saving strategies
    mapping(address => uint256) savingAssets;

    /// @dev Approved token transfer amounts on behalf of others
    mapping(address => mapping(address => uint256)) transferAllowances;

    /// @dev Hat list
    Hat[] hats;

    /// @dev Account structure
    struct Account {
        //
        // Essential info
        //
        /// @dev ID of the hat selected for the account
        uint256 hatID;
        /// @dev Redeemable token balance for the account
        uint256 rAmount;
        /// @dev Redeemable token balance portion that is from interest payment
        uint256 rInterest;
        /// @dev Loan recipients and their amount of debt
        mapping (address => uint256) lRecipients;
        /// @dev Loan debt amount for the account
        uint256 lDebt;
        /// @dev Saving asset amount
        uint256 sAmount;

        /// @dev Stats
        AccountStats stats;
    }

    /// @dev Account mapping
    mapping (address => Account) accounts;

    /**
     * @dev Transfer `tokens` tokens from `src` to `dst` by `spender`
            Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferInternal(address spender, address src, address dst, uint256 tokens) internal returns (bool) {
        require(src != dst, "src should not equal dst");
        require(accounts[src].rAmount >= tokens, "Not enough balance to transfer");

        /* Get the allowance, infinite for the account owner */
        uint256 startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint256(-1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }
        require(startingAllowance >= tokens, "Not enough allowance for transfer");

        /* Do the calculations, checking for {under,over}flow */
        uint256 allowanceNew = startingAllowance.sub(tokens);
        uint256 srcTokensNew = accounts[src].rAmount.sub(tokens);
        uint256 dstTokensNew = accounts[dst].rAmount.add(tokens);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // apply hat inheritance rule
        if (accounts[src].hatID != 0 && accounts[dst].hatID == 0) {
            changeHatInternal(dst, accounts[src].hatID);
        }

        accounts[src].rAmount = srcTokensNew;
        accounts[dst].rAmount = dstTokensNew;

        /* Eat some of the allowance (if necessary) */
        if (startingAllowance != uint256(-1)) {
            transferAllowances[src][spender] = allowanceNew;
        }

        // lRecipients adjustments
        uint256 sAmountCollected = estimateAndRecollectLoans(src, tokens);
        distributeLoans(dst, tokens, sAmountCollected);

        // rInterest adjustment for src
        if (accounts[src].rInterest > accounts[src].rAmount) {
            accounts[src].rInterest = accounts[src].rAmount;
        }

        /* We emit a Transfer event */
        emit Transfer(src, dst, tokens);

        return true;
    }

    /**
     * @dev Sender supplies assets into the market and receives rTokens in exchange
     * @dev Invest into underlying assets immediately
     * @param mintAmount The amount of the underlying asset to supply
     */
    function mintInternal(uint256 mintAmount) internal {
        IERC20 token = IERC20(cToken.underlying());
        require(token.allowance(msg.sender, address(this)) >= mintAmount, "Not enough allowance");

        Account storage account = accounts[msg.sender];

        // mint c tokens
        token.transferFrom(msg.sender, address(this), mintAmount);
        token.approve(address(cToken), mintAmount);
        uint256 cTotalBefore = cToken.totalSupply();
        require(cToken.mint(mintAmount) == 0, "mint failed");
        uint256 cTotalAfter = cToken.totalSupply();
        uint256 cMintedAmount;
        if (cTotalAfter > cTotalBefore) {
            cMintedAmount = cTotalAfter - cTotalBefore;
        } // else can there be case that we mint but we get less cTokens!?

        // update global and account r balances
        totalSupply = totalSupply.add(mintAmount);
        account.rAmount = account.rAmount.add(mintAmount);

        // update global stats
        savingAssets[ss] += cMintedAmount;

        // distribute saving assets as loans to recipients
        distributeLoans(msg.sender, mintAmount, cMintedAmount);

        emit Mint(msg.sender, mintAmount);
        emit Transfer(address(this), msg.sender, mintAmount);
    }

    /**
     * @notice Sender redeems rTokens in exchange for the underlying asset
     * @dev Withdraw equal amount of initially supplied underlying assets
     * @param redeemTokens The number of rTokens to redeem into underlying
     */
    function redeemInternal(uint256 redeemTokens) internal {
        IERC20 token = IERC20(cToken.underlying());

        Account storage account = accounts[msg.sender];
        require(redeemTokens > 0, "Redeem amount cannot be zero");
        require(redeemTokens <= account.rAmount, "Not enough balance to redeem");

        uint256 sAmountCollected = redeemAndRecollectLoans(msg.sender, redeemTokens);

        // update Account r balances and global statistics
        account.rAmount = account.rAmount.sub(redeemTokens);
        if (account.rInterest > account.rAmount) {
            account.rInterest = account.rAmount;
        }
        totalSupply = totalSupply.sub(redeemTokens);

        // update global stats
        savingAssets[ss] -= sAmountCollected;

        // transfer the token back
        token.transfer(msg.sender, redeemTokens);

        emit Transfer(msg.sender, address(this), redeemTokens);
        emit Redeem(msg.sender, redeemTokens);
    }

    /**
     * @dev Create a new Hat
     * @param recipients List of beneficial recipients
     * @param proportions Relative proportions of benefits received by the recipients
     */
    function createHatInternal(
        address[] memory recipients,
        uint32[] memory proportions) internal returns (uint256 hatID) {
        uint i;

        require(recipients.length > 0, "Invalid hat: at least one recipient");
        require(recipients.length == proportions.length, "Invalid hat: length not matching");

        // normalize the proportions
        uint256 totalProportions = 0;
        for (i = 0; i < recipients.length; ++i) {
            require(proportions[i] > 0, "Invalid hat: proportion should be larger than 0");
            totalProportions += uint256(proportions[i]);
        }
        for (i = 0; i < proportions.length; ++i) {
            proportions[i] = uint32(
                uint256(proportions[i])
                * uint256(PROPORTION_BASE)
                / totalProportions);
        }

        hatID = hats.push(Hat(
            recipients,
            proportions
        )) - 1;
        emit HatCreated(hatID);
    }

    /**
     * @dev Change the hat for `owner`
     * @param owner Account owner
     * @param hatID The id of the Hat
     */
    function changeHatInternal(address owner, uint256 hatID) internal {
        Account storage account = accounts[owner];
        if (account.rAmount > 0) {
            uint256 sAmountCollected = estimateAndRecollectLoans(owner, account.rAmount);
            account.hatID = hatID;
            distributeLoans(owner, account.rAmount, sAmountCollected);
        } else {
            account.hatID = hatID;
        }
        emit HatChanged(owner, hatID);
    }

    /**
     * @dev Get interest payable of the account
     */
    function getInterestPayableOf(Account storage account) internal view returns (uint256) {
        uint256 rGross = account.sAmount
            .mul(cToken.exchangeRateStored())
            .div(10 ** 18);
        if (rGross > (account.lDebt + account.rInterest)) {
            return rGross - account.lDebt - account.rInterest;
        } else {
            // no interest accumulated yet or even negative interest rate!?
            return 0;
        }
    }

    /**
     * @dev Distribute the incoming tokens to the recipients as loans.
     *      The tokens are immediately invested into the saving strategy and
     *      add to the sAmount of the recipient account.
     *      Recipient also inherits the owner's hat if it does already have one.
     * @param owner Owner account address
     * @param rAmount rToken amount being loaned to the recipients
     * @param sAmount Amount of saving assets being given to the recipients
     */
    function distributeLoans(
            address owner,
            uint256 rAmount,
            uint256 sAmount) internal {
        Account storage account = accounts[owner];
        Hat storage hat = hats[account.hatID == SELF_HAT_ID ? 0 : account.hatID];
        bool[] memory recipientsNeedsNewHat = new bool[](hat.recipients.length);
        uint i;
        if (hat.recipients.length > 0) {
            uint256 rLeft = rAmount;
            uint256 sLeft = sAmount;
            for (i = 0; i < hat.proportions.length; ++i) {
                Account storage recipient = accounts[hat.recipients[i]];
                bool isLastRecipient = i == (hat.proportions.length - 1);

                // inherit the hat if needed
                if (recipient.hatID == 0) {
                    recipientsNeedsNewHat[i] = true;
                }

                uint256 lDebtRecipient = isLastRecipient ? rLeft :
                    rAmount
                    * hat.proportions[i]
                    / PROPORTION_BASE;
                account.lRecipients[hat.recipients[i]] = account.lRecipients[hat.recipients[i]].add(lDebtRecipient);
                recipient.lDebt = recipient.lDebt.add(lDebtRecipient);
                // leftover adjustments
                if (rLeft > lDebtRecipient) {
                    rLeft -= lDebtRecipient;
                } else {
                    rLeft = 0;
                }

                uint256 sAmountRecipient = isLastRecipient ? sLeft:
                    sAmount
                    * hat.proportions[i]
                    / PROPORTION_BASE;
                recipient.sAmount = recipient.sAmount.add(sAmountRecipient);
                // leftover adjustments
                if (sLeft >= sAmountRecipient) {
                    sLeft -= sAmountRecipient;
                } else {
                    rLeft = 0;
                }
            }
        } else {
            // Account uses the zero hat, give all interest to the owner
            account.lDebt = account.lDebt.add(rAmount);
            account.sAmount = account.sAmount.add(sAmount);
        }

        // apply to new hat owners
        for (i = 0; i < hat.proportions.length; ++i) {
            if (recipientsNeedsNewHat[i]) {
                changeHatInternal(hat.recipients[i], account.hatID);
            }
        }
    }

    /**
     * @dev Recollect loans from the recipients for further distribution
     *      without actually redeeming the saving assets
     * @param owner Owner account address
     * @param rAmount rToken amount neeeds to be recollected from the recipients
     *                by giving back estimated amount of saving assets
     * @return Estimated amount of saving assets needs to recollected
     */
    function estimateAndRecollectLoans(
        address owner,
        uint256 rAmount) internal returns (uint256 cEstimatedAmount) {
        Account storage account = accounts[owner];
        Hat storage hat = hats[account.hatID == SELF_HAT_ID ? 0 : account.hatID];
        // accrue interest so estimate is up to date
        cToken.accrueInterest();
        cEstimatedAmount = rAmount
            .mul(10 ** 18)
            .div(cToken.exchangeRateStored());
        recollectLoans(account, hat, rAmount, cEstimatedAmount);
    }

    /**
     * @dev Recollect loans from the recipients for further distribution
     *      by redeeming the saving assets in `rAmount`
     * @param owner Owner account address
     * @param rAmount rToken amount neeeds to be recollected from the recipients
     *                by redeeming equivalent value of the saving assets
     * @return Amount of saving assets redeemed for rAmount of tokens.
     */
    function redeemAndRecollectLoans(
        address owner,
        uint256 rAmount) internal returns (uint256 cBurnedAmount) {
        Account storage account = accounts[owner];
        Hat storage hat = hats[account.hatID == SELF_HAT_ID ? 0 : account.hatID];
        uint256 cTotalBefore = cToken.totalSupply();
        require(cToken.redeemUnderlying(rAmount) == 0, "redeemUnderlying failed");
        uint256 cTotalAfter = cToken.totalSupply();
        if (cTotalAfter < cTotalBefore) {
            cBurnedAmount = cTotalBefore - cTotalAfter;
        } // else can there be case that we end up with more cTokens ?!
        recollectLoans(account, hat, rAmount, cBurnedAmount);
    }

    /**
     * @dev Recollect loan from the recipients
     * @param account Owner account
     * @param hat     Owner's hat
     * @param rAmount rToken amount being written of from the recipients
     * @param sAmount Amount of sasving assets recollected from the recipients
     */
    function recollectLoans(
        Account storage account,
        Hat storage hat,
        uint256 rAmount,
        uint256 sAmount) internal {
        uint i;
        if (hat.recipients.length > 0) {
            uint256 rLeft = rAmount;
            uint256 sLeft = sAmount;
            for (i = 0; i < hat.proportions.length; ++i) {
                Account storage recipient = accounts[hat.recipients[i]];
                bool isLastRecipient = i == (hat.proportions.length - 1);

                uint256 lDebtRecipient = isLastRecipient ? rLeft: rAmount
                    * hat.proportions[i]
                    / PROPORTION_BASE;
                if (recipient.lDebt > lDebtRecipient) {
                    recipient.lDebt -= lDebtRecipient;
                } else {
                    recipient.lDebt = 0;
                }
                if (account.lRecipients[hat.recipients[i]] > lDebtRecipient) {
                    account.lRecipients[hat.recipients[i]] -= lDebtRecipient;
                } else {
                    account.lRecipients[hat.recipients[i]] = 0;
                }
                // leftover adjustments
                if (rLeft > lDebtRecipient) {
                    rLeft -= lDebtRecipient;
                } else {
                    rLeft = 0;
                }

                uint256 sAmountRecipient = isLastRecipient ? sLeft:
                    sAmount
                    * hat.proportions[i]
                    / PROPORTION_BASE;
                if (recipient.sAmount > sAmountRecipient) {
                    recipient.sAmount -= sAmountRecipient;
                } else {
                    recipient.sAmount = 0;
                }
                // leftover adjustments
                if (sLeft >= sAmountRecipient) {
                    sLeft -= sAmountRecipient;
                } else {
                    rLeft = 0;
                }
            }
        } else {
            // Account uses the zero hat, recollect interests from the owner
            if (account.lDebt > rAmount) {
                account.lDebt -= rAmount;
            } else {
                account.lDebt = 0;
            }
            if (account.sAmount > sAmount) {
                account.sAmount -= sAmount;
            } else {
                account.sAmount = 0;
            }
        }
    }
}
