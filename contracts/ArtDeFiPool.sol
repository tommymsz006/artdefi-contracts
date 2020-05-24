pragma solidity ^0.5.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
//import "@openzeppelin/contracts/math/SafeMath.sol";	// included in Ray Math

import { LendingPool } from "./abis/aave-protocol/LendingPool.sol";
import { LendingPoolCore } from "../../aave-protocol/contracts/lendingpool/LendingPoolCore.sol";
import { ILendingPoolAddressesProvider } from "../../aave-protocol/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import { AToken } from "../../aave-protocol/contracts/tokenization/AToken.sol";
import "../../aave-protocol/contracts/libraries/WadRayMath.sol";

contract ArtDeFiPool is Ownable {
	using Math for uint256;
	using SafeMath for uint256;
  using WadRayMath for uint256;

	uint256 internal constant UNLOCK_AMOUNT = uint256(1000000000000000000000000000);
	uint256 internal constant VARIABLE_INTEREST_RATE_MODE = uint256(2);	// variable rate
	uint16 internal constant REFERRAL_CODE = uint16(0);					// no referral

	ILendingPoolAddressesProvider public addressesProvider;	// Aave LendingPool address provider
  address public liquidityReserveAddress;			// reserve address for liquidity (e.g. DAI)
	address public liquidityATokenAddress;			// Aave aToken address for liquidity (e.g. aETH)
	address public loanReserveAddress;					// reserve address for loan (e.g. USDC)

  mapping (address => uint256) private userLiquidityIndexes;
  mapping (address => uint256) private userPrincipals;
  mapping (address => uint256) private userBorrowIndexes;
  mapping (address => uint256) private userLoanPrincipals;

	constructor(address _providerAddress, address _liquidityReserveAddress, address _liquidityATokenAddress, address _loanReserveAddress)
							public {
		addressesProvider = ILendingPoolAddressesProvider(_providerAddress);
		liquidityReserveAddress = _liquidityReserveAddress;
		liquidityATokenAddress = _liquidityATokenAddress;
		loanReserveAddress = _loanReserveAddress;
	}

	function deposit(uint256 _amount) external payable {
		// transfer the underliner to this pool
		IERC20(liquidityReserveAddress).transferFrom(msg.sender, address(this), _amount);

		// approve LendingPoolCore to move the ERC-20 token of the underliner
		IERC20(liquidityReserveAddress).approve(addressesProvider.getLendingPoolCore(), _amount);

	  /* ETH
		require(_amount <= msg.value);
		uint256 depositAmount = _amount.min(msg.value);
		uint256 excessAmount = msg.value.sub(depositAmount);
		*/

		// set user states
		_cumulateUserBalance(msg.sender, _amount, true);

		// deposit the amount to Aave
		LendingPool(addressesProvider.getLendingPool()).deposit(liquidityReserveAddress, _amount, REFERRAL_CODE);

		/* ETH
		LendingPool(addressesProvider.getLendingPool()).deposit.value(_amount)(liquidityReserveAddress, _amount, REFERRAL_CODE);
		msg.sender.transfer(excessAmount);
		*/
	}

	function withdraw(uint256 _amount) external payable {
		// check _amount is withdrawable
		require(_amount <= getCumulatedUserBalance(msg.sender));

		// redeem aToken to get corresponding ERC-20 token
		AToken aToken = AToken(liquidityATokenAddress);
		aToken.redeem(_amount);

		// set user state and cumulate balance
		_cumulateUserBalance(msg.sender, _amount, false);

		// return the amount back to the sender
		IERC20(liquidityReserveAddress).transfer(msg.sender, _amount);
		/* ETH
		msg.sender.transfer(_amount);
		*/
	}

	function borrow(uint256 _amount) external {
		// borrow the amount
		LendingPool(addressesProvider.getLendingPool()).borrow(loanReserveAddress, _amount, VARIABLE_INTEREST_RATE_MODE, REFERRAL_CODE);

		// set user states
		_cumulateUserLoan(msg.sender, _amount, true);

		// return the amount back to the sender
		IERC20(loanReserveAddress).transfer(msg.sender, _amount);
	}

	function repay(uint256 _amount) external payable {
		uint256 repayAmount = _amount.min(getCumulatedUserLoan(msg.sender));
		uint256 excessAmount = _amount.sub(repayAmount);

		// transfer the underliner to this pool
		IERC20(loanReserveAddress).transferFrom(msg.sender, address(this), _amount);

		// approve LendingPoolCore to move ERC20 token
		IERC20(loanReserveAddress).approve(addressesProvider.getLendingPoolCore(), repayAmount);

		// set user state and lower loan
		_cumulateUserLoan(msg.sender, repayAmount, false);

		// repay the loan
		LendingPool(addressesProvider.getLendingPool()).repay(loanReserveAddress, repayAmount, address(this));

		// refund the user if there is excess amount
		if (excessAmount > 0) {
			IERC20(loanReserveAddress).transfer(msg.sender, excessAmount);
		}
	}

	function getCumulatedUserBalance(address _user) public view returns(uint256) {
		//return userPrincipals[_user] * _getLiquidityIndex() / _getUserLiquidityIndex(_user);	// normal uint256 math
		return userPrincipals[_user].wadToRay().rayMul(_getLiquidityIndex()).rayDiv(_getUserLiquidityIndex(_user)).rayToWad();	// use Ray Math
	}

	function _getLiquidityIndex() internal view returns(uint256) {
		// note: getReserveNormalizedIncome() returns the most updated income, getReserveData() provides the last save index (which has delays)
		//(,,,,,,,,,uint256 liquidityIndex,,,) = LendingPool(addressesProvider.getLendingPool()).getReserveData(liquidityReserveAddress);
		//return liquidityIndex;
		return LendingPoolCore(addressesProvider.getLendingPoolCore()).getReserveNormalizedIncome(liquidityReserveAddress);
	}

	function _getUserLiquidityIndex(address _user) internal view returns(uint256) {
		return (userLiquidityIndexes[_user] == 0) ? _getLiquidityIndex() : userLiquidityIndexes[_user];
	}

	function _cumulateUserBalance(address _user, uint256 _amount, bool _isCredit) internal {
		userPrincipals[_user] = _isCredit ? (getCumulatedUserBalance(_user).add(_amount)): (getCumulatedUserBalance(_user).sub(_amount));
		userLiquidityIndexes[_user] = (userPrincipals[_user] > 0) ? _getLiquidityIndex() : 0;
	}

	function getCumulatedUserLoan(address _user) public view returns(uint256) {
		return userLoanPrincipals[_user].wadToRay().rayMul(_getBorrowIndex()).rayDiv(_getUserBorrowIndex(_user)).rayToWad();	// use Ray Math
	}

	function _getBorrowIndex() internal view returns(uint256) {
		// note: getUserBorrowBalances() returns the most updated loan balances, getUserVariableBorrowCumulativeIndex() & getUserVariableBorrowCumulativeIndex() only return last saved index (which has delays)
		LendingPoolCore core = LendingPoolCore(addressesProvider.getLendingPoolCore());
		(uint256 loanPrincipal, uint256 loan,) = core.getUserBorrowBalances(loanReserveAddress, address(this));
		return (loanPrincipal > 0)
							? loan.wadToRay().rayMul(core.getUserVariableBorrowCumulativeIndex(loanReserveAddress, address(this))).rayDiv(loanPrincipal.wadToRay())
							: core.getReserveVariableBorrowsCumulativeIndex(loanReserveAddress);	// best effort
	}

	function _getUserBorrowIndex(address _user) internal view returns(uint256) {
		return (userBorrowIndexes[_user] == 0) ? _getBorrowIndex() : userBorrowIndexes[_user];
	}

	function _cumulateUserLoan(address _user, uint256 _amount, bool _isCredit) internal {
		userLoanPrincipals[_user] = _isCredit ? (getCumulatedUserLoan(_user).add(_amount)): (getCumulatedUserLoan(_user).sub(_amount));
		userBorrowIndexes[_user] = (userLoanPrincipals[_user] > 0) ? _getBorrowIndex() : 0;
	}

  // withdraw remaining reserve tokens in the contract
  function clearReserve()
    public
    onlyOwner
  {
    require(IERC20(liquidityReserveAddress).transfer(msg.sender, IERC20(liquidityReserveAddress).balanceOf(address(this))), "Unable to transfer");
    require(IERC20(loanReserveAddress).transfer(msg.sender, IERC20(loanReserveAddress).balanceOf(address(this))), "Unable to transfer");
  }

  function clearAToken()
    public
    onlyOwner
  {
		AToken aToken = AToken(liquidityATokenAddress);
		aToken.redeem(aToken.balanceOf(address(this)));
  }
}
