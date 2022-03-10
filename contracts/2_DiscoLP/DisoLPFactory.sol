pragma solidity ^0.6.0;

import './DiscoLP.sol';
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IUniswapV2Factory {
  event PairCreated(address indexed token0, address indexed token1, address pair, uint);

  function getPair(address tokenA, address tokenB) external view returns (address pair);
  function allPairs(uint) external view returns (address pair);
  function allPairsLength() external view returns (uint);

  function feeTo() external view returns (address);
  function feeToSetter() external view returns (address);

  function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract Token2 is ERC20 {
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) public {
    _mint(msg.sender, 100000 * 10 ** 18); // initial LP liquidity
    _mint(tx.origin, 1 * 10 ** 18); // a tip to user
  }
}

contract DiscoLPFactory {
    address public disco_lp;
    address public token_a_jimbo;
    address public token_b_jambo;
    address public reserveToken;

    function createInstance(address _factory, address _router) public {
        address factory = _factory;
        address router = _router;
        ERC20 tokenA = new Token2("Jimbo", "JIMBO");
        ERC20 tokenB = new Token2("Jambo", "JAMBO");
        reserveToken = IUniswapV2Factory(factory).createPair(address(tokenA), address(tokenB));
        DiscoLP instance = new DiscoLP("DiscoLP", "DISCO", 18, reserveToken, router);
        

        disco_lp = address(instance);
        token_a_jimbo = address(tokenA);
        token_b_jambo = address(tokenB);


        tokenA.approve(router, uint256(-1));
        tokenB.approve(router, uint256(-1));
        (uint256 amountA, uint256 amountB, uint256 _shares) = Router02(router).addLiquidity(
            address(tokenA),
            address(tokenB),
            100000 * 10 ** 18,
            100000 * 10 ** 18,
            1, 1, disco_lp, uint256(-1));

        
    }

}