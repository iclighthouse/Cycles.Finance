/**
 * Module     : CF.mo (CyclesFinance Types)
 * Author     : ICLight.house Team
 * License    : GNU General Public License v3.0
 * Stability  : Experimental
 * Canister   : ium3d-eqaaa-aaaak-aab4q-cai
 * Website    : https://cycles.finance
 * Github     : https://github.com/iclighthouse/
 */
module {
  public type Config = {
    FEE : ?Nat;
    MIN_ICP_E8S : ?Nat;
    ICP_LIMIT : ?Nat;
    MIN_CYCLES : ?Nat;
    MAX_STORAGE_TRIES : ?Nat;
    STORAGE_CANISTER : ?Text;
    MAX_CACHE_NUMBER_PER : ?Nat;
    MAX_CACHE_TIME : ?Nat;
    CYCLES_LIMIT : ?Nat;
    ICP_FEE : ?Nat64;
  };
  public type ErrorLog = {
    withdraw : (Principal, Nat, Principal, Nat);
    time : Timestamp;
    user : Principal;
  };
  public type FeeStatus = {
    fee : Float;
    cumulFee : { icpBalance : Nat; cyclesBalance : Nat };
    totalFee : { icpBalance : Nat; cyclesBalance : Nat };
    myAllocable : ?{ icpBalance : Nat; cyclesBalance : Nat };
  };
  public type ICP = { e8s : Nat64 };
  public type Liquidity = {
    icp : ICP;
    vol : Vol;
    shareWeighted : ShareWeighted;
    unitValue : (Float, Float);
    share : Nat;
    cycles : Nat;
    priceWeighted : PriceWeighted;
    swapCount : Nat64;
  };
  public type OperationType = {
    #AddLiquidity;
    #Swap;
    #Claim;
    #RemoveLiquidity;
  };
  public type PriceWeighted = {
    updateTime : Timestamp;
    icpTimeWeighted : Nat;
    cyclesTimeWeighted : Nat;
  };
  public type ShareChange = { #Burn : Nat; #Mint : Nat; #NoChange };
  public type ShareWeighted = {
    updateTime : Timestamp;
    shareTimeWeighted : Nat;
  };
  public type Time = Int;
  public type Timestamp = Nat;
  public type TokenType = { #Icp; #DRC20 : Principal; #Cycles };
  public type TokenValue = { #In : Nat; #Out : Nat; #NoChange };
  public type Txid = [Nat8];
  public type TxnRecord = {
    fee : { token0Fee : Nat; token1Fee : Nat };
    data : ?[Nat8];
    time : Time;
    txid : Txid;
    token0Value : TokenValue;
    share : ShareChange;
    token0 : TokenType;
    token1 : TokenType;
    operation : OperationType;
    account : Principal;
    token1Value : TokenValue;
    cyclesWallet : ?Principal;
  };
  public type TxnResult = {
    icpE8s : TokenValue;
    txid : Txid;
    share : ShareChange;
    cycles : TokenValue;
  };
  public type Vol = { swapIcpVol : Nat; swapCyclesVol : Nat };
  public type Self = actor {
    add : shared (Principal, ?[Nat8]) -> async TxnResult;
    claim : shared (Principal, ?[Nat8]) -> async TxnResult;
    count : shared query ?Principal -> async Nat;
    cyclesToIcp : shared (Principal, ?[Nat8]) -> async TxnResult;
    feeStatus : shared query ?Principal -> async FeeStatus;
    getAccountId : shared query Principal -> async Text;
    getConfig : shared query () -> async Config;
    getEvents : shared query ?Principal -> async [TxnRecord];
    icpToCycles : shared (Nat, Principal, ?[Nat8]) -> async TxnResult;
    lastTxids : shared query ?Principal -> async [Txid];
    liquidity : shared query ?Principal -> async Liquidity;
    remove : shared (?Nat, Principal, ?[Nat8]) -> async TxnResult;
    txnRecord : shared query Txid -> async ?TxnRecord;
  }
}