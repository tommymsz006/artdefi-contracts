pragma solidity ^0.5.0;

import "@openzeppelin/contracts/ownership/Ownable.sol";

import "@chainlink/contracts/src/v0.5/ChainlinkClient.sol";

contract ArtDeFiEvaluator is ChainlinkClient, Ownable {

  string internal constant API_THEGRAPH = "https://api.thegraph.com/subgraphs/name/tommymsz006/superrare-v2"; // TheGraph API path for SuperRare
  string internal constant ELEMENT_TOTAL_PRIMARY_INCOME = "totalPrimaryIncome";
  string internal constant ELEMENT_TOTAL_ROYALTY = "totalRoyalty";
  uint256 internal constant LINK_PAYMENT = 1 * LINK; // 1 LINK

  bytes32 public jobId;
  mapping (bytes32 => address) public requestId2User;
  mapping (address => uint256) public userArtworkIncome;

  constructor(address _oracle, bytes32 _jobId) public {
    // Set the address for the LINK token for the network
    setPublicChainlinkToken();
    setChainlinkOracle(_oracle);

    jobId = _jobId; // do string to bytes32 conversion off-chain at migration time
  }

  function populateUserArtworkIncome(string calldata _userAddress) external {
    // reset stored artwork income, if any
    userArtworkIncome[msg.sender] = uint256(0);

    // send requests to Chainlink
    _requestTheGraph(_userAddress, ELEMENT_TOTAL_PRIMARY_INCOME);
    _requestTheGraph(_userAddress, ELEMENT_TOTAL_ROYALTY);
  }

  // Creates a Chainlink request with the uint256 multiplier job
  function _requestTheGraph(string memory _userAddress, string memory _element) internal {
    Chainlink.Request memory req = buildChainlinkRequest(jobId, address(this), this.fulfill.selector);

    req.add("post", API_THEGRAPH);
    //req.add("body", "{\"query\": \"{account(id: \\\"0xd656f8d9cb8fa5aeb8b1576161d0488ee2c9c926\\\") {totalRoyalty}}\"}");
    //req.add("body", string(abi.encodePacked("{\"query\": \"{account(id: \\\"", "0xd656f8d9cb8fa5aeb8b1576161d0488ee2c9c926", "\\\") {", _element, "}}\"}")));
    req.add("body", string(abi.encodePacked("{\"query\": \"{account(id: \\\"", _userAddress, "\\\") {", _element, "}}\"}")));
    string[] memory path = new string[](3);
    path[0] = "data";
    path[1] = "account";
    path[2] = _element;
    req.addStringArray("path", path);

    // sends the request to the oracle with specified payment amount
    bytes32 requestId = sendChainlinkRequest(req, LINK_PAYMENT);
    requestId2User[requestId] = msg.sender;
  }

  // fulfill bytes32 data type
  function fulfill(bytes32 _requestId, bytes32 _result)
    public
    recordChainlinkFulfillment(_requestId)  // this can only be executed by the desired requesting oracle
  {
    // add artwork income to the user
    userArtworkIncome[requestId2User[_requestId]] = userArtworkIncome[requestId2User[_requestId]] + _bytes32ToUint256(_result);
  }

  function evaluateScoring(address _userAddress, uint256 _loanAmount) external view returns(uint256) {
    uint256 pct;
    if (_loanAmount <= userArtworkIncome[_userAddress]) {
      pct = 1000;
    } else if (_loanAmount >= userArtworkIncome[_userAddress] * 11) {
      pct = 0;
    } else {
      pct = uint256(1100).sub(_loanAmount.mul(100).div(userArtworkIncome[_userAddress]));
    }
    return pct;
  }

  // cancelRequest allows the owner to cancel a given unfulfilled request
  function cancelRequest(
    bytes32 _requestId,
    uint256 _payment,
    bytes4 _callbackFunctionId,
    uint256 _expiration
  )
    public
    onlyOwner
  {
    cancelChainlinkRequest(_requestId, _payment, _callbackFunctionId, _expiration);
  }

  // withdrawLink allows the owner to withdraw any extra LINK in the contract
  function withdrawLink()
    public
    onlyOwner
  {
    LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
    require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
  }

  function _bytes32ToUint256(bytes32 _source) private pure returns (uint256 output) {
    uint i;
    output = 0;
    for (i = 0; i < 32; i++) {
        uint c = uint(uint8(_source[i])); // need to cast explicitly to uint8 first for 1 byte
        if (c >= 48 && c <= 57) {
            output = output * 10 + (c - 48);
        }
    }
  }

/*
  function stringToBytes32(string memory _source) private pure returns (bytes32 output) {
    bytes memory tempEmptyStringTest = bytes(_source);
    if (tempEmptyStringTest.length == 0) {
      return 0x0;
    }

    assembly { // solhint-disable-line no-inline-assembly
      output := mload(add(_source, 32))
    }
  }
*/
}