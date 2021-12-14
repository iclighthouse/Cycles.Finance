import Ledger "../sys/Ledger2";
import Time "mo:base/Time";
module {
    public type Timestamp = Nat; // seconds (Time.Time/1000000000)
    public type AccountId = Blob;
    // type Price = (cycles: Nat, icp: Nat); // x cycles per y icp
    public type ShareWeighted = {
        shareTimeWeighted: Nat; 
        updateTime: Timestamp; 
    };
    public type CumulShareWeighted = Nat;
    public type Vol = {
        swapCyclesVol: Nat;
        swapIcpVol: Nat; 
    };
    public type PriceWeighted = {
        cyclesTimeWeighted: Nat; // cyclesTimeWeighted += cycles*seconds
        icpTimeWeighted: Nat;
        updateTime: Timestamp; 
    };
    public type FeeBalance = {
        var cyclesBalance: Nat;
        var icpBalance: Nat;
    };
    public type Liquidity = {
        cycles: Nat;
        icp: Ledger.ICP;
        share: Nat;
        shareWeighted: ShareWeighted;
        cumulShareWeighted: CumulShareWeighted;
        unitValue: (cycles: Float, icpE8s: Float);
        vol: Vol;
        priceWeighted: PriceWeighted;
        swapCount: Nat64;
    };
    public type FeeStatus = {
        fee: Float;
        cumulFee: {
            cyclesBalance: Nat;
            icpBalance: Nat;
        };
        totalFee: {
            cyclesBalance: Nat;
            icpBalance: Nat;
        };
        myAllocable: ?{
            cyclesBalance: Nat;
            icpBalance: Nat;
        };
    };
    public type ErrorLog = {
        user: Principal;
        withdraw: (cyclesWallet: Principal, cycles: Nat, icpAccount: Principal, icp: Nat);
        time: Timestamp;
    };
    public type TokenType = {
        #Cycles;
        #Icp;
        #DRC20: Principal;
    };
    public type Txid = Blob;
    public type Config = { 
        MIN_CYCLES: ?Nat;
        MIN_ICP_E8S: ?Nat;
        ICP_FEE: ?Nat64;
        FEE: ?Nat;
        ICP_LIMIT: ?Nat;
        CYCLES_LIMIT: ?Nat;
        MAX_CACHE_TIME: ?Nat;
        MAX_CACHE_NUMBER_PER: ?Nat;
        STORAGE_CANISTER: ?Text;
        MAX_STORAGE_TRIES: ?Nat;
    };
    public type OperationType = {
        #AddLiquidity;
        #RemoveLiquidity;
        #Claim;
        #Swap;
    };
    public type TokenValue = {
        #In: Nat;
        #Out: Nat;
        #NoChange;
    };
    public type ShareChange = {
        #Mint: Nat;
        #Burn: Nat;
        #NoChange;
    };
    public type TxnRecord = {
        txid: Txid;
        operation: OperationType;
        account: Principal;
        cyclesWallet: ?Principal;
        token0: TokenType;
        token1: TokenType;
        token0Value: TokenValue;
        token1Value: TokenValue;
        fee: {token0Fee: Nat; token1Fee: Nat; };
        share: ShareChange;
        time: Time.Time;
        data: ?Blob;
    };
    public type TxnResult = {
        txid: Txid;
        cycles: TokenValue;
        icpE8s: TokenValue;
        share: ShareChange;
    };
}