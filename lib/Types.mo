import Ledger "../sys/Ledger2";
import Time "mo:base/Time";
import Result "mo:base/Result";

module {
    public type Timestamp = Nat; // seconds (Time.Time/1000000000)
    public type Address = Text;
    public type AccountId = Blob;
    public type Sa = [Nat8];
    public type CyclesWallet = Principal;
    public type CyclesAmount = Nat;
    public type IcpE8s = Nat;
    public type Shares = Nat;
    public type Nonce = Nat;
    public type Data = Blob;
    public type Txid = Blob;
    // type Price = (cycles: Nat, icp: Nat); // x cycles per y icp
    public type ShareWeighted = {
        shareTimeWeighted: Nat; 
        updateTime: Timestamp; 
    };
    public type CumulShareWeighted = Nat;
    public type Vol = {
        swapCyclesVol: CyclesAmount;
        swapIcpVol: IcpE8s; 
    };
    public type PriceWeighted = {
        cyclesTimeWeighted: Nat; // cyclesTimeWeighted += cycles*seconds
        icpTimeWeighted: Nat;
        updateTime: Timestamp; 
    };
    public type FeeBalance = {
        var cyclesBalance: CyclesAmount;
        var icpBalance: IcpE8s;
    };
    public type Liquidity = {
        cycles: Nat;
        icpE8s: IcpE8s;
        shares: Shares;
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
            cyclesBalance: CyclesAmount;
            icpBalance: IcpE8s;
        };
        totalFee: {
            cyclesBalance: CyclesAmount;
            icpBalance: IcpE8s;
        };
        myPortion: ?{
            cyclesBalance: CyclesAmount;
            icpBalance: IcpE8s;
        };
    };
    public type TransStatus = {
        #Processing;
        #Success;
        #Failure;
        #Fallback;
    };
    public type IcpTransferLog = {from: AccountId; to: AccountId; value: IcpE8s; status: TransStatus; updateTime: Timestamp};
    public type CyclesTransferLog = {from: Principal; to: Principal; value: CyclesAmount; status: TransStatus; updateTime: Timestamp};
    public type ErrorLog = {
        #IcpSaToMain: {
            user: AccountId;
            debit: (index: Nat64, sa: AccountId, icp: IcpE8s);
            errMsg: Ledger.TransferError;
            time: Timestamp;
        };
        #Withdraw: {
            user: AccountId;
            credit: (cyclesWallet: CyclesWallet, cycles: CyclesAmount, icpAccount: AccountId, icp: IcpE8s);
            cyclesErrMsg: Text;
            icpErrMsg: ?Ledger.TransferError;
            time: Timestamp;
        };
    };
    public type ErrorAction = {#delete; #fallback; #resendIcp; #resendCycles; #resendIcpCycles;};
    
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

    public type TokenType = {
        #Cycles;
        #Icp;
        #Token: Principal;
    };
    public type OperationType = {
        #AddLiquidity;
        #RemoveLiquidity;
        #Claim;
        #Swap;
    };
    public type BalanceChange = {
        #DebitRecord: Nat;
        #CreditRecord: Nat;
        #NoChange;
    };
    public type ShareChange = {
        #Mint: Shares;
        #Burn: Shares;
        #NoChange;
    };
    public type TxnRecord = {
        txid: Txid;
        msgCaller: ?Principal;
        caller: AccountId;
        operation: OperationType;
        account: AccountId;
        cyclesWallet: ?CyclesWallet;
        token0: TokenType;
        token1: TokenType;
        token0Value: BalanceChange;
        token1Value: BalanceChange;
        fee: {token0Fee: Nat; token1Fee: Nat; };
        shares: ShareChange;
        time: Time.Time;
        index: Nat;
        nonce: Nonce;
        data: ?Data;
    };
    public type TxnResult = Result.Result<{   //<#ok, #err> 
            txid: Txid;
            cycles: BalanceChange;
            icpE8s: BalanceChange;
            shares: ShareChange;
        }, {
            code: {
                #NonceError;
                #InvalidCyclesAmout;
                #InvalidIcpAmout;
                #InsufficientShares;
                #PoolIsEmpty;
                #IcpTransferException;
                #UnacceptableVolatility;
                #UndefinedError;
            };
            message: Text;
        }>;
}