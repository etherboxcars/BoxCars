pragma solidity ^0.4.21;

/// @title A 19 round pre-commitment block hash based dice game
/**
  an experimental contract to test a multi-player blockchain game, and trial a 
  'pre-commitment' mechanism using the blockhash for randomness, with the hope of
  getting feedback from the blockchain community on the suitability of this 
  mechanism for more advanced roleplaying and 'board' games.
  
  The contract is a simple pre-commitment dice game, where players bet at even odds
  whether they can roll a 'double six' in 19 'rolls'.  Each roll is a personalised random roll 
  based on the block hash and the player address.  Players bet using 'placeBet' and must collect
  their winnings within 255 blocks (approximately one hour) using 'resolveBet'.
*/

contract BoxCars {

  address public owner;					// the contract owner

  struct bet {							// a simple indexed data structure to track player bets
    uint start_block;					// - the block number when the bet starts
    uint bet_amount;					// - the amount bet
    uint player_index;					// - the index of the bet owner in the player array
  }

  mapping(address => bet) bets;         // current outstanding bets, indexed by player
  address[] players;                    // array of current players

  uint public houseBankroll = 0;        // how much free wei the house has to bet (e.g. total account value - double the value of outstanding bets)

  event LogBetMade(address accountAddress, uint amount);
  event LogBetWon(address accountAddress, uint amount);
  event LogBetLost(address accountAddress, uint amount);
  event LogTopUp(uint amount);

  event LogMessage(string msg, uint value);
  
  modifier onlyOwner() {
    require (msg.sender == owner);
    _;
  }


  /**
   *  Initialises the Contract
   */

  constructor() public {
    owner = msg.sender;
  }

  /**
   * Called by a player to place a bet. A player may only have one bet active at a time. 
   * The method checks and resolves any existing bet first, and fails if a bet is already  
   * in progress, or if the value is outside maximum and minimum limits.
   */

  function placeBet() public payable {
	emit LogMessage("starting bet", msg.value);
    resolveBet();							  // pays out or clears any existing bet if it is finished
	
    require (bets[msg.sender].bet_amount==0); // a player can only have one bet at a time, so quits if a bet is still running
    require (msg.value < getMaximumBet());	  // bet is too big
    require (msg.value > getMinimumBet() );   // bet is too small 
	require (players.length < 10); 			  // cap number of players to a max of 10
	 	
    addBet(msg.sender, msg.value);			  // set up the bet with a start block number and a bet amount 
  }

  /**
   * see if a particular player has an active bet (used by the UX)
   */

  function playerHasBet(address player) public view returns (bool active) {
     return (bets[player].bet_amount!=0);
  }

  /**
   * Sets a limit to the maximum bet, to avoid house being wiped out all at once.
   * note - there's a risk that multiple players bet the max simultaneously, in which case only the first will succeed)
   */

  function getMaximumBet() public view returns (uint max) {
     max = houseBankroll/8;
  }

  /**
   * Sets a lower limit to bets, so that the contract doesn't get DOS-ed.  
   * (Is this even necessary, given gas costs?)
   */

  function getMinimumBet() public view returns (uint min) {
     min = houseBankroll/256;
  }

  /**
   *  Called by a player to resolve any existing bets:  
   *  If they have won, pays out bet to player, 
   *  if they have lost, cleans up old bet and house takes bet,  
   *  If bet not won, but still in play, does nothing. 
   */

  function resolveBet() public {
    cleanupOldBets();                                          		// remove *all* bets more than 256 blocks old (including any from calling player)

	if (bets[msg.sender].bet_amount > 0) {                     		// check the calling player's bets
      if (isWinningBet()) {                            				// if it's a winner...  
 
				  
        uint bet_amount = bets[msg.sender].bet_amount;  	    	// ...get the amount won		   
        removeBet(bets[msg.sender].player_index);		       		// ...delete bet 		
		emit LogBetWon(msg.sender, bet_amount);   
        msg.sender.transfer(2*bet_amount);					       	// ...payout twice bet amount to winner
      } 
      else if (block.number > bets[msg.sender].start_block + 19) { 	// bet hasn't won, so...
            houseTakesBet(bets[msg.sender].player_index);	   	  	// ...if the bet has run its course, delete losing bet 		
      }
    }
  }

  /**
   *  This cleans up any expired bets.  It probably doesn't need to be public,
   *  but is calleable independantly in case we need to do housekeeping.
   */

  function cleanupOldBets() public {  
    if (players.length>0) {   
	  for (uint index=players.length; index>0; index--) {				// WARNING - The players array is mutable, so iterate from top to bottom
	  if (bets[getPlayer(index-1)].start_block + 255 < block.number)     // cleanup any expired bets
	    houseTakesBet(index-1);									        // WARNING - this alters player array	
	  }
	}
  }

  /**
   *  Convenience function that displays dice rolls for the message sender.
   *  WARNING: Can't get this to work when called from metamask - something to do with returning an array?  
   *           - works fine in test suite.
   */
  function displayDiceRoll(uint blockNumber) public view returns (uint8[2]) {   
     uint8 roll = getDiceRoll(blockNumber, msg.sender);
     return translateDiceRoll(roll);
  }  

  /**
  * takes a number between 1 and 36 inclusive and turns it into two dice rolls; each 1-6 inclusive.
  */

  function translateDiceRoll(uint8 roll) public pure returns (uint8[2]) {
     require(roll<=36);
 
     if (roll == 0) { 							// zero result for expired bet
       return ([0,0]); 
     }   
     uint8 diceA = uint8(1 + ((roll-1)/6));
     uint8 diceB = uint8(1 + ((roll-1)%6));
     return ([diceA, diceB]);
  }

  /**
   *  returns a blockhash based random number between 1 and 36, 
   *  (or 0 if no block hash is available, e.g. due to an expired block).
   */

  function getDiceRoll(uint blockNumber, address player) public view returns (uint8 roll) {
      if (blockNumber + 255 > block.number && blockNumber <= block.number) {
          bytes32 result = keccak256(abi.encodePacked(player, blockhash(blockNumber)));
          return uint8(1+(uint256(result)%36));  // ignore miniscule modulus bias...
      }
      return 0;  // not valid to ask for rolls more than 255 blocks old...
  }


  /*
   *				PRIVATE FUNCTIONS
   */


  /**
   *  Called by 'placeBet()', this creates the bet data structure, adds the bet to the list of current bets, 
   *  and sequestors part of the house bankroll to cover the bet.
   */

  function addBet(address player, uint amount) private {
    require(amount < houseBankroll);  				

    bets[player].start_block = block.number + 1;  // the bet starts on the next block...
    bets[player].bet_amount = amount;
    bets[player].player_index = players.length;
    players.push(player);
    houseBankroll = houseBankroll - amount;

    emit LogBetMade(player, amount);
  }


  /**
   * return bet funds to the houseBankroll
   */
 
  function houseTakesBet(uint index) private {
	address player = players[index];
    uint bet_amount = bets[player].bet_amount;              
    bets[player].bet_amount = 0;
    houseBankroll += (2*bet_amount);						// house recovers bet *and* the bankroll put aside								

	emit LogBetLost(player, bet_amount);   		  
    
    removeBet(index);										// remove the bet from the list of bets
  }

  /*
   * Housekeeping to manage players dynamic array and bets mapping
   * This deletes a player from the mapping and array, and shrinks the array.
   */

  function removeBet(uint indexToDelete) private {
    address player = players[indexToDelete];				// player to remove
    delete bets[player];									// remove player bet

    if (indexToDelete+1 < players.length) {
      address listHeadAddress = players[players.length-1];	// get player at head of array
      players[indexToDelete] = listHeadAddress;				// copy over the top of the removed player...
      bets[listHeadAddress].player_index = indexToDelete;	// ... and update bet pointer to player array 	
    }
 
    players.length--;										// deletes the head of the array
  }


  /**
   *  Evaluates whether a particular bet is a winner based on evaluating
   *  up to 19 blockhashes after 'start_block'.
   */ 
  function isWinningBet() private returns (bool win) {	
      win = false;
      uint start_block = bets[msg.sender].start_block;

      // check if bet has timed out
      if (block.number > start_block + 255)
      {
          removeBet(bets[msg.sender].player_index);  // can't access blocks more than 255 blocks old
          return false;
      }

      // a bet can be checked before all 19 blocks have passed
      uint endBlock = (block.number > start_block + 19)?start_block+19:block.number;
      for (uint checkBlock = start_block; checkBlock < endBlock; checkBlock++) {
		if (getDiceRoll(checkBlock, msg.sender) == 36)
		  return true;
      }
      return false;
  }

  /*
   * accesses player bet details based on player index in the players array
   */
  function getPlayerBetstart_block(uint playerIndex) private view returns (uint blockNumber)  {
     address playerAddress = players[playerIndex];
     blockNumber = bets[playerAddress].start_block;
  }


  /*
   * accesses player bet details based on player index in the players array
   */
  function getPlayerBetAmount(uint playerIndex) private view returns (uint betAmount) {
     address playerAddress = players[playerIndex];
     betAmount = bets[playerAddress].bet_amount;
  }

  /*
   * accesses player address based on player index in the players array
   */
  function getPlayer(uint playerIndex) private view returns (address player)  {
     player = players[playerIndex];
  }

 
  // *** administrative and monitoring functions ***

  // explicitly reject fallback payments - included for clarity and to stop accidental bets
  function () public payable {
    revert () ; 
  } 

  /**
   * Allows the owner to withdraw funds that have not been set aside to cover bets
   */

  function withdraw(uint amount) onlyOwner public  {
    require(amount <= houseBankroll);
    houseBankroll -= amount;
    owner.transfer(amount);
  }

  /**
   * Allows owner to add funds to the house bankroll
   */

  function topUp() payable onlyOwner public  {
	emit LogTopUp(msg.value);
    houseBankroll += msg.value;
  }

  /**
   *  Allows owner to monitor bankroll
   */

  function getBankroll() onlyOwner public view returns (uint bankroll) {
    bankroll = houseBankroll;
  }

  /**
   *  Allows owner to 'reset' bankroll if it somehow gets out of synch with the account balance
   */

  function reset() onlyOwner public {
	if (players.length==0) houseBankroll = address(this).balance;  // which it should anyway, but this is insurance which resets everything.	
  }


  /**
   *  Allows owner to view list of current players
   */

  function listPlayers() public view onlyOwner returns (address[]) {
      return players;
  }

  /**
   *  Allows the owner to shut down the contract, as long as there are no active bets.
   * (Contract is intended as test only...!)
   */

  function kill() onlyOwner public { 
    if (players.length==0) { selfdestruct(owner); }
  }
}
