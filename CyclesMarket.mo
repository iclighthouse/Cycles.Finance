/**
 * Module     : CyclesMarket.mo
 * Author     : ICLight.house Team
 * License    : GNU General Public License v3.0
 * Stability  : Experimental
 * Canister   : 6nmrm-laaaa-aaaak-aacfq-cai
 * Website    : https://cycles.finance
 * Github     : https://github.com/iclighthouse/
 */
import Array "mo:base/Array";
import Binary "./lib/Binary";
import Blob "mo:base/Blob";
import Cycles "mo:base/ExperimentalCycles";
import CyclesWallet "./sys/CyclesWallet";
import Deque "mo:base/Deque";
import Float "mo:base/Float";
import Hash "mo:base/Hash";
import Hex "./lib/Hex";
import Int "mo:base/Int";
import Int64 "mo:base/Int64";
import Ledger "./sys/Ledger2";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:⛔";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Tools "./lib/Tools";
import SHA224 "./lib/SHA224";
import Trie "mo:base/Trie";
import Error "mo:base/Error";
import T "./lib/Types";
import DRC207 "./lib/DRC207";
import DRC205 "./lib/DRC205";

shared(installMsg) actor class CyclesMarket() = this {
    type Timestamp = T.Timestamp;  //seconds
    type Address = T.Address;
    type AccountId = T.AccountId;  //Blob
    type Sa = T.Sa;
    type CyclesWallet = T.CyclesWallet;
    type CyclesAmount = T.CyclesAmount;
    type IcpE8s = T.IcpE8s;
    type Shares = T.Shares;
    type Nonce = T.Nonce;
    type Data = T.Data;
    type ShareWeighted = T.ShareWeighted;
    type CumulShareWeighted = T.CumulShareWeighted;
    type Vol = T.Vol;
    type PriceWeighted = T.PriceWeighted;
    type FeeBalance = T.FeeBalance;
    type Liquidity = T.Liquidity;
    type FeeStatus = T.FeeStatus;
    type TransStatus = T.TransStatus;
    type IcpTransferLog = T.IcpTransferLog;
    type CyclesTransferLog = T.CyclesTransferLog;
    type ErrorLog = T.ErrorLog;
    type ErrorAction = T.ErrorAction;
    type Txid = T.Txid;  //Blob
    type Config = T.Config;
    type TxnRecord = T.TxnRecord;
    type TxnResult = T.TxnResult;

    private stable var MIN_CYCLES: Nat = 100000000;
    private stable var MIN_ICP_E8S: Nat = 10000;
    private stable var ICP_FEE: Nat64 = 10000; // e8s 
    private stable var FEE: Nat = 10000; // = feeRate * 1000000  (value 10000 means 1.0%)
    private stable var ICP_LIMIT: Nat = 10*100000000;  // e8s 
    private stable var CYCLES_LIMIT: Nat = 300*1000000000000; //cycles
    private stable var MAX_CACHE_TIME: Nat = 3 * 30 * 24 * 3600 * 1000000000; //  3 months
    private stable var MAX_CACHE_NUMBER_PER: Nat = 100;
    private stable var STORAGE_CANISTER: Text = "6ylab-kiaaa-aaaak-aacga-cai";
    private stable var MAX_STORAGE_TRIES: Nat = 5; 

    private let version_: Text = "0.5";
    private let ledger: Ledger.Self = actor("ryjl3-tyaaa-aaaaa-aaaba-cai");
    private func _now() : Timestamp{
        return Int.abs(Time.now() / 1000000000);
    };

    private stable var pause: Bool = false; 
    private stable var owner: Principal = installMsg.caller;
    private stable var k: Nat = 0; // icp*cycles
    private stable var poolCycles: Nat = 0;
    private stable var poolIcp: Nat = 0;
    private stable var poolShare: Nat = 0;
    private stable var unitValue: Nat = 1000000; // =e8s/share * 1000000
    private stable var poolShareWeighted: ShareWeighted = { shareTimeWeighted = 0; updateTime = _now(); };
    private stable var priceWeighted: PriceWeighted = { cyclesTimeWeighted = 0; icpTimeWeighted = 0; updateTime = _now(); };
    private stable var totalVol: Vol = { swapCyclesVol = 0; swapIcpVol = 0;};
    private stable var cumulFee: FeeBalance = { var cyclesBalance = 0; var icpBalance = 0; };
    private stable var feeBalance: FeeBalance = { var cyclesBalance = 0; var icpBalance = 0; };
    private stable var itIndex: Nat64 = 0;  
    private stable var icpTransferLogs: Trie.Trie<Nat, IcpTransferLog> = Trie.empty();
    private stable var cyclesTransferLogs: Trie.Trie<Nat, CyclesTransferLog> = Trie.empty();
    private stable var ctIndex: Nat64 = 0;  

    private stable var shares: Trie.Trie<AccountId, (Nat, ShareWeighted, CumulShareWeighted)> = Trie.empty();
    private stable var vols: Trie.Trie<AccountId, Vol> = Trie.empty(); 
    private stable var inProgress = List.nil<(cyclesWallet: CyclesWallet, cycles: CyclesAmount, icpAccount: AccountId, icp: IcpE8s)>();
    private stable var errors: Trie.Trie<Nat, ErrorLog> = Trie.empty(); 
    private stable var errorIndex: Nat = 0;
    private stable var errorHistory = List.nil<(Nat, ErrorLog, ErrorAction, ?CyclesWallet)>();
    private stable var nonces: Trie.Trie<AccountId, Nonce> = Trie.empty(); 
    private stable var txnRecords: Trie.Trie<Txid, TxnRecord> = Trie.empty();
    private stable var globalTxns = Deque.empty<(Txid, Time.Time)>();
    private stable var globalLastTxns = Deque.empty<Txid>();
    private stable var index: Nat = 0;
    // storage
    private stable var accountLastTxns: Trie.Trie<AccountId, Deque.Deque<Txid>> = Trie.empty();
    private stable var storeRecords = List.nil<(Txid, Nat)>();
    //private stable var top100Vol: [(AccountId, Nat)] = []; //token1
    //private stable var top100Liquidity: [(AccountId, Nat)] = []; //shares 
    
    /* 
    * Local Functions
    */
    private func _onlyOwner(_caller: Principal) : Bool { 
        return _caller == owner;
    };  // assert(_onlyOwner(msg.caller));
    private func _notPaused() : Bool { 
        return not(pause);
    };
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Hash.hash(t) }; };
    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };

    private func _getNonce(_a: AccountId): Nat{
        switch(Trie.get(nonces, keyb(_a), Blob.equal)){
            case(?(v)){
                return v;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _addNonce(_a: AccountId): (){
        var n = _getNonce(_a);
        nonces := Trie.put(nonces, keyb(_a), Blob.equal, n+1).0;
        index += 1;
    };
    private func _checkNonce(_a: AccountId, _nonce: ?Nonce) : Bool{
        switch(_nonce){
            case(?(n)){ return n == _getNonce(_a); };
            case(_){ return true; };
        };
    };

    private func _getAccountId(_address: Address): AccountId{
        switch (Tools.accountHexToAccountBlob(_address)){
            case(?(a)){
                return a;
            };
            case(_){
                var p = Principal.fromText(_address);
                var a = Tools.principalToAccountBlob(p, null);
                return a;
            };
        };
    }; 
    private func _getSA(_sa: Blob) : Blob{
        var sa = Blob.toArray(_sa);
        while (sa.size() < 32){
            sa := Array.append([0:Nat8], sa);
        };
        return Blob.fromArray(sa);
    };
    private func _getMainAccount() : AccountId{
        let main = Principal.fromActor(this);
        return Blob.fromArray(Tools.principalToAccount(main, null));
    };
    private func _getAccountIdFromPrincipal(_p: Principal, _sa: ?[Nat8]): AccountId{
        var a = Tools.principalToAccountBlob(_p, _sa);
        return a;
    };
    private func _getDepositAccount(_a: AccountId) : AccountId{
        let main = Principal.fromActor(this);
        let sa = Blob.toArray(_a);
        return Blob.fromArray(Tools.principalToAccount(main, ?sa));
    };
    private func _getIcpBalance(_a: AccountId) : async Nat{ //e8s
        let res = await ledger.account_balance({
            account = _a;
        });
        return Nat64.toNat(res.e8s);
    };
    private func _sendIcpFromMA(_to: AccountId, _value: IcpE8s) : async Ledger.TransferResult{
        var amount = Nat64.fromNat(_value);
        amount := if (amount > ICP_FEE){ amount - ICP_FEE } else { 0 };
        var res: Ledger.TransferResult = #Err(#TxCreatedInFuture);
        let _itIndex = itIndex;
        try{
            res := await ledger.transfer({
                to = _to;
                fee = { e8s = ICP_FEE; };
                memo = itIndex;
                from_subaccount = null;
                created_at_time = ?{timestamp_nanos = Nat64.fromIntWrap(Time.now())};
                amount = { e8s = amount };
            });
            switch(res){
                case(#Err(e)){ 
                    _putIcpTransferLog(_itIndex, _getMainAccount(), _to, Nat64.toNat(amount), #Failure);
                };
                case(_){ //
                    _putIcpTransferLog(_itIndex, _getMainAccount(), _to, Nat64.toNat(amount), #Success);
                };
            };
        }catch(e){
            _putIcpTransferLog(_itIndex, _getMainAccount(), _to, Nat64.toNat(amount), #Processing);
        };
        return res;
    };
    private func _sendIcpFromSA(_fromSa: AccountId, _value: IcpE8s) : async Ledger.TransferResult{
        var amount = Nat64.fromNat(_value);
        let to = _getMainAccount();
        amount := if (amount > ICP_FEE){ amount - ICP_FEE } else { 0 };
        var res: Ledger.TransferResult = #Err(#TxCreatedInFuture);
        let _itIndex = itIndex;
        try{
            res := await ledger.transfer({
                to = to;
                fee = { e8s = ICP_FEE; };
                memo = itIndex;
                from_subaccount = ?_getSA(_fromSa);
                created_at_time = null;
                amount = { e8s = amount };
            });
            switch(res){
                case(#Err(e)){ 
                    _putIcpTransferLog(_itIndex, _fromSa, to, Nat64.toNat(amount), #Failure);
                    errors := Trie.put(errors, keyn(errorIndex), Nat.equal, #IcpSaToMain({
                        user = _fromSa;
                        debit = (itIndex, _fromSa, _value);
                        errMsg = e;
                        time = _now();
                    })).0;
                    errorIndex += 1;
                };
                case(_){ //
                    _putIcpTransferLog(_itIndex, _fromSa, to, Nat64.toNat(amount), #Success);
                };
            };
        }catch(e){
            _putIcpTransferLog(_itIndex, _fromSa, to, Nat64.toNat(amount), #Processing);
        };
        return res;
    };
    private func _putIcpTransferLog(_itIndex: Nat64, _from: AccountId, _to: AccountId, _value: Nat, _setStatus: TransStatus) : (){
        icpTransferLogs := Trie.put(icpTransferLogs, keyn(Nat64.toNat(_itIndex)), Nat.equal, {
            from = _from;
            to = _to;
            value = _value; // not included fee
            fee = Nat64.toNat(ICP_FEE);
            status = _setStatus;
            updateTime = _now();
        }).0;
        if (_itIndex > 10000){
            icpTransferLogs := Trie.remove(icpTransferLogs, keyn(Nat64.toNat(_itIndex-10000)), Nat.equal).0;
        };
        if (_itIndex == itIndex) { itIndex += 1; };
    };
    private func _putCyclesTransferLog(_ctIndex: Nat64, _from: Principal, _to: Principal, _value: Nat, _setStatus: TransStatus) : (){
        cyclesTransferLogs := Trie.put(cyclesTransferLogs, keyn(Nat64.toNat(_ctIndex)), Nat.equal, {
            from = _from;
            to = _to;
            value = _value;
            status = _setStatus;
            updateTime = _now();
        }).0;
        if (_ctIndex > 10000){
            cyclesTransferLogs := Trie.remove(cyclesTransferLogs, keyn(Nat64.toNat(_ctIndex-10000)), Nat.equal).0;
        };
        if (_ctIndex == ctIndex) { ctIndex += 1; };
    };
    private func _subIcpFee(_icpE8s: IcpE8s) : Nat{
        if (_icpE8s > Nat64.toNat(ICP_FEE)){
            return Nat.sub(_icpE8s, Nat64.toNat(ICP_FEE));
        }else {
            return 0;
        };
    };
    private func _getPriceWeighted() : PriceWeighted{
        var now = _now();
        if (now < priceWeighted.updateTime){ now := priceWeighted.updateTime; };
        return {
            cyclesTimeWeighted = priceWeighted.cyclesTimeWeighted + poolCycles * Nat.sub(now, priceWeighted.updateTime);
            icpTimeWeighted = priceWeighted.icpTimeWeighted + poolIcp * Nat.sub(now, priceWeighted.updateTime);
            updateTime = now;
        };
    };
    private func _addLiquidity(_addCycles: CyclesAmount, _addIcp: IcpE8s) : (){
        priceWeighted := _getPriceWeighted();
        poolCycles += _addCycles;
        poolIcp += _addIcp;
        k := poolCycles * poolIcp;
        //if (poolShare > 0 ){ _updateUnitValue(); };
    };
    private func _removeLiquidity(_subCycles: CyclesAmount, _subIcp: IcpE8s) : (){
        priceWeighted := _getPriceWeighted();
        poolCycles -= _subCycles;
        poolIcp -= _subIcp;
        k := poolCycles * poolIcp; 
        //if (poolShare > 0 ){ _updateUnitValue(); };
    };
    private func _updateLiquidity(_newCycles: CyclesAmount, _newIcp: IcpE8s) : (){
        priceWeighted := _getPriceWeighted();
        poolCycles := _newCycles;
        poolIcp := _newIcp;
        k := poolCycles * poolIcp;
        if (poolShare > 0 ){ _updateUnitValue(); };
    };
    private func _updateUnitValue() : (){
        unitValue := poolIcp*1000000 / poolShare;
    };
    private func _calcuShare(_cyclesAmout: CyclesAmount, _icpAmout: IcpE8s) : Nat{
        return _icpAmout*1000000 / unitValue;
    };
    private func _shareToAmount(_share: Shares) : {cycles: CyclesAmount; icp: IcpE8s}{
        return {
            cycles = poolCycles * _share * unitValue / 1000000 / poolIcp; 
            icp = _share * unitValue / 1000000;
        };
    };
    private func _getPoolShareWeighted() : ShareWeighted{
        var now = _now();
        if (now < poolShareWeighted.updateTime){ now := poolShareWeighted.updateTime; };
        return {
            shareTimeWeighted = poolShareWeighted.shareTimeWeighted + poolShare * Nat.sub(now, poolShareWeighted.updateTime);
            updateTime = now;
        };
    };
    private func _updatePoolShare(_newShare: Shares) : (){
        poolShareWeighted := _getPoolShareWeighted();
        poolShare := _newShare;
    };
    private func _getShare(_a: AccountId) : (Nat, ShareWeighted, CumulShareWeighted){ 
        var now = _now();
        switch(Trie.get(shares, keyb(_a), Blob.equal)){
            case(?(share)){
                if (now < share.1.updateTime){ now := share.1.updateTime; };
                let newShareTimeWeighted = share.1.shareTimeWeighted + share.0 * Nat.sub(now, share.1.updateTime);
                let newCumulShareWeighted = share.2 + share.0 * Nat.sub(now, share.1.updateTime);
                return (share.0, {shareTimeWeighted = newShareTimeWeighted; updateTime = now;}, newCumulShareWeighted);
            };
            case(_){
                return (0, {shareTimeWeighted = 0; updateTime = now;}, 0);
            };
        };
    };
    private func _updateShare(_a: AccountId, _newShare: Shares) : (){
        let share = _getShare(_a);
        shares := Trie.put(shares, keyb(_a), Blob.equal, (_newShare, share.1, share.2)).0;
    };
    private func _getVol(_a: AccountId) : Vol{
        switch(Trie.get(vols, keyb(_a), Blob.equal)){
            case(?(vol)){
                return vol;
            };
            case(_){
                return { swapCyclesVol = 0; swapIcpVol = 0;};
            };
        };
    };
    private func _updateVol(_a: AccountId, _addCyclesVol: CyclesAmount, _addIcpVol: IcpE8s) : (){
        totalVol := {
            swapCyclesVol = totalVol.swapCyclesVol + _addCyclesVol;
            swapIcpVol = totalVol.swapIcpVol + _addIcpVol;
        };
        switch(Trie.get(vols, keyb(_a), Blob.equal)){
            case(?(vol)){
                let newVol = {
                    swapCyclesVol = vol.swapCyclesVol + _addCyclesVol;
                    swapIcpVol = vol.swapIcpVol + _addIcpVol;
                };
                vols := Trie.put(vols, keyb(_a), Blob.equal, newVol).0;
            };
            case(_){
                vols := Trie.put(vols, keyb(_a), Blob.equal, {
                    swapCyclesVol = _addCyclesVol;
                    swapIcpVol = _addIcpVol;
                }).0;
            };
        };
    };
    private func _withdraw() : async (){
        var item = List.pop(inProgress);
        while (Option.isSome(item.0)){
            inProgress := item.1;
            switch(item.0){
                case(?(cyclesWallet, cycles, icpAccount, icp)){
                    var temp = (cyclesWallet, 0, icpAccount, 0);
                    var cyclesErrMsg: Text = "";
                    var icpErrMsg: ?Ledger.TransferError = null;
                    if (cycles >= MIN_CYCLES){
                        var mainBalance = Cycles.balance();
                        let _ctIndex = ctIndex;
                        try{
                            let wallet: CyclesWallet.Self = actor(Principal.toText(cyclesWallet));
                            Cycles.add(cycles);
                            await wallet.wallet_receive();
                            _putCyclesTransferLog(_ctIndex, Principal.fromActor(this), cyclesWallet, cycles, #Success);
                        } catch(e){ 
                            cyclesErrMsg := Error.message(e);
                            temp := (temp.0, cycles, temp.2, temp.3);
                            _putCyclesTransferLog(_ctIndex, Principal.fromActor(this), cyclesWallet, cycles, #Failure);
                        };
                    };
                    if (icp >= MIN_ICP_E8S){
                        var mainBalance: Nat = 0;
                        try{
                            mainBalance := Nat64.toNat((await ledger.account_balance({account = _getMainAccount()})).e8s);
                            let res = await _sendIcpFromMA(icpAccount, icp);
                            switch(res){
                                case(#Err(e)){ icpErrMsg := ?e; throw Error.reject("ICP sending error!");};
                                case(_){};
                            };
                        } catch(e){ 
                            temp := (temp.0, temp.1, temp.2, icp);
                            // var mainBalance2: Nat = 0;
                            // try{
                            //     mainBalance2 := Nat64.toNat((await ledger.account_balance({account = _getMainAccount()})).e8s);
                            //     if (mainBalance < MIN_ICP_E8S or Nat.sub(mainBalance, mainBalance2) < icp){
                            //         temp := (temp.0, temp.1, temp.2, icp);
                            //     };
                            // } catch(e){
                            //     temp := (temp.0, temp.1, temp.2, icp);
                            // };
                        };
                    };
                    if (temp.1 >= MIN_CYCLES or temp.3 >= MIN_ICP_E8S){
                        errors := Trie.put(errors, keyn(errorIndex), Nat.equal, #Withdraw({
                            user = temp.2;
                            credit = (temp.0, temp.1, temp.2, temp.3);
                            cyclesErrMsg = cyclesErrMsg;
                            icpErrMsg = icpErrMsg;
                            time = _now();
                        })).0;
                        errorIndex += 1;
                    };
                };
                case(_){};
            };
            item := List.pop(inProgress);
        };
    };
    private func _chargeFee(_cyclesFee: CyclesAmount, _icpFee: IcpE8s) : (){
        feeBalance.cyclesBalance += _cyclesFee*8/10;
        feeBalance.icpBalance += _icpFee;
        cumulFee.cyclesBalance += _cyclesFee*8/10;
        cumulFee.icpBalance += _icpFee;
    };
    private func _volatility(_newPoolCycles: CyclesAmount, _newPoolIcp: IcpE8s) : Nat{
        let rate1 = poolCycles / poolIcp;
        let rate2 = _newPoolCycles / _newPoolIcp;
        var dif: Nat = 0;
        if (rate2 > rate1){
            dif := Nat.sub(rate2, rate1) * 100 / rate1;
        }else {
            dif := Nat.sub(rate1, rate2) * 100 / rate1;
        };
        return dif;
    };
    private func _getTxid(_caller: AccountId) : Txid{
        return DRC205.generateTxid(Principal.fromActor(this), _caller, _getNonce(_caller));
    };
    private func _getTxnRecord(_txid: Txid): ?TxnRecord{
        return Trie.get(txnRecords, keyb(_txid), Blob.equal);
    };
    private func _insertTxnRecord(_txn: TxnRecord): (){
        var txid = _txn.txid;
        txnRecords := Trie.put(txnRecords, keyb(txid), Blob.equal, _txn).0;
        _pushGlobalTxns(txid);
        _pushLastTxn(_txn.account, txid);
    };
    private func _deleteTxnRecord(_txid: Txid): (){
        switch(_getTxnRecord(_txid)){
            case(?(txn)){
                let _a = txn.account;
                _cleanLastTxns(_a);
            };
            case(_){};
        };
        txnRecords := Trie.remove(txnRecords, keyb(_txid), Blob.equal).0;
    };
    private func _pushGlobalTxns(_txid: Txid): (){
        // push new txid.
        globalTxns := Deque.pushFront(globalTxns, (_txid, Time.now()));
        globalLastTxns := Deque.pushFront(globalLastTxns, _txid);
        var size = List.size(globalLastTxns.0) + List.size(globalLastTxns.1);
        while (size > MAX_CACHE_NUMBER_PER){
            size -= 1;
            switch (Deque.popBack(globalLastTxns)){
                case(?(q, v)){
                    globalLastTxns := q;
                };
                case(_){};
            };
        };
        // pop expired txids, and delete their records.
        switch(Deque.peekBack(globalTxns)){
            case (?(txid, ts)){
                var timestamp: Time.Time = ts;
                while (Time.now() - timestamp > MAX_CACHE_TIME){
                    switch (Deque.popBack(globalTxns)){
                        case(?(q, v)){
                            globalTxns := q;
                            _deleteTxnRecord(v.0); // delete the record.
                        };
                        case(_){};
                    };
                    switch(Deque.peekBack(globalTxns)){
                        case(?(txid_,ts_)){
                            timestamp := ts_;
                        };
                        case(_){
                            timestamp := Time.now();
                        };
                    };
                };
            };
            case(_){};
        };
    };
    private func _getGlobalLastTxns(): [Txid]{
        var l = List.append(globalLastTxns.0, List.reverse(globalLastTxns.1));
        return List.toArray(l);
    };
    private func _getLastTxns(_a: AccountId): [Txid]{
        switch(Trie.get(accountLastTxns, keyb(_a), Blob.equal)){
            case(?(swaps)){
                var l = List.append(swaps.0, List.reverse(swaps.1));
                return List.toArray(l);
            };
            case(_){
                return [];
            };
        };
    };
    private func _cleanLastTxns(_a: AccountId): (){
        switch(Trie.get(accountLastTxns, keyb(_a), Blob.equal)){
            case(?(swaps)){  
                var txids: Deque.Deque<Txid> = swaps;
                var size = List.size(txids.0) + List.size(txids.1);
                while (size > MAX_CACHE_NUMBER_PER){
                    size -= 1;
                    switch (Deque.popBack(txids)){
                        case(?(q, v)){
                            txids := q;
                        };
                        case(_){};
                    };
                };
                switch(Deque.peekBack(txids)){
                    case (?(txid)){
                        let txn_ = _getTxnRecord(txid);
                        switch(txn_){
                            case(?(txn)){
                                var timestamp = txn.time;
                                while (Time.now() - timestamp > MAX_CACHE_TIME and size > 0){
                                    switch (Deque.popBack(txids)){
                                        case(?(q, v)){
                                            txids := q;
					                        size -= 1;
                                        };
                                        case(_){};
                                    };
                                    switch(Deque.peekBack(txids)){
                                        case(?(txid)){
                                            let txn_ = _getTxnRecord(txid);
                                            switch(txn_){
                                                case(?(txn)){ timestamp := txn.time; };
                                                case(_){ timestamp := Time.now(); };
                                            };
                                        };
                                        case(_){ timestamp := Time.now(); };
                                    };
                                };
                            };
                            case(_){};
                        };
                    };
                    case(_){};
                };
                if (size == 0){
                    accountLastTxns := Trie.remove(accountLastTxns, keyb(_a), Blob.equal).0;
                }else{
                    accountLastTxns := Trie.put(accountLastTxns, keyb(_a), Blob.equal, txids).0;
                };
            };
            case(_){};
        };
    };
    private func _pushLastTxn(_a: AccountId, _txid: Txid): (){
        switch(Trie.get(accountLastTxns, keyb(_a), Blob.equal)){
            case(?(q)){
                var txids: Deque.Deque<Txid> = q;
                txids := Deque.pushFront(txids, _txid);
                accountLastTxns := Trie.put(accountLastTxns, keyb(_a), Blob.equal, txids).0;
                _cleanLastTxns(_a);
            };
            case(_){
                var new = Deque.empty<Txid>();
                new := Deque.pushFront(new, _txid);
                accountLastTxns := Trie.put(accountLastTxns, keyb(_a), Blob.equal, new).0;
            };
        };
    };
    // records storage (DRC205 Standard)
    private func _drc205Store() : async (){
        let drc205: DRC205.Self = actor(STORAGE_CANISTER);
        var _storeRecords = List.nil<(Txid, Nat)>();
        var item = List.pop(storeRecords);
        let storageFee = await drc205.fee();
        while (Option.isSome(item.0)){
            storeRecords := item.1;
            switch(item.0){
                case(?(txid, callCount)){
                    if (callCount < MAX_STORAGE_TRIES){
                        switch(_getTxnRecord(txid)){
                            case(?(txn)){
                                try{
                                    Cycles.add(storageFee);
                                    await drc205.store(txn);
                                } catch(e){ //push
                                    _storeRecords := List.push((txid, callCount+1), _storeRecords);
                                };
                            };
                            case(_){};
                        };
                    };
                };
                case(_){};
            };
            item := List.pop(storeRecords);
        };
        storeRecords := _storeRecords;
    };

    /* 
    * Shared Functions
    */
    // public query func getK() : async Nat{
    //     return k;
    // };
    public query func version() : async Text{
        return version_;
    };
    public query func getConfig() : async Config{
        return { 
            MIN_CYCLES = ?MIN_CYCLES;
            MIN_ICP_E8S = ?MIN_ICP_E8S;
            ICP_FEE = ?ICP_FEE;
            FEE = ?FEE;
            ICP_LIMIT = ?ICP_LIMIT;
            CYCLES_LIMIT = ?CYCLES_LIMIT;
            MAX_CACHE_TIME = ?MAX_CACHE_TIME;
            MAX_CACHE_NUMBER_PER = ?MAX_CACHE_NUMBER_PER;
            STORAGE_CANISTER = ?STORAGE_CANISTER;
            MAX_STORAGE_TRIES = ?MAX_STORAGE_TRIES;
        };
    };
    public query func getAccountId(_account: Address) : async Text{
        return Hex.encode(Blob.toArray(_getDepositAccount(_getAccountId(_account))));
    };
    public query func liquidity(_account: ?Address) : async Liquidity{
        let unitIcp = unitValue;
        let unitCycles = unitIcp * poolCycles / poolIcp;
        let unitIcpFloat = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(unitIcp))) / 1000000;
        let unitCyclesFloat = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(unitCycles))) / 1000000;
        switch(_account) {
            case(null){
                return {
                    cycles = poolCycles;
                    icpE8s = poolIcp;
                    shares = poolShare;
                    shareWeighted = _getPoolShareWeighted();
                    cumulShareWeighted = _getPoolShareWeighted().shareTimeWeighted;
                    unitValue = (unitCyclesFloat, unitIcpFloat);
                    vol = totalVol;
                    priceWeighted = _getPriceWeighted();
                    swapCount = Nat64.fromNat(index);
                };
            };
            case(?(_a)){
                let account = _getAccountId(_a);
                let (share, shareWeighted, cumulShareWeighted) = _getShare(account);
                let vol = _getVol(account);
                return {
                    cycles = poolCycles * share / poolShare;
                    icpE8s = poolIcp * share / poolShare;
                    shares = share;
                    shareWeighted = shareWeighted;
                    cumulShareWeighted = cumulShareWeighted;
                    unitValue = (unitCyclesFloat, unitIcpFloat);
                    vol = vol;
                    priceWeighted = _getPriceWeighted();
                    swapCount = Nat64.fromNat(_getNonce(account));
                };
            };
        };
    };
    public query func feeStatus(_account: ?Address) : async FeeStatus{
        switch(_account) {
            case(null){
                return {
                    fee = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(FEE))) / 1000000;
                    cumulFee = { cyclesBalance = cumulFee.cyclesBalance; icpBalance = cumulFee.icpBalance; };
                    totalFee = { cyclesBalance = feeBalance.cyclesBalance; icpBalance = feeBalance.icpBalance; };
                    myPortion = null;
                };
            };
            case(?(_a)){
                let account = _getAccountId(_a);
                let shareWeighted = _getShare(account).1;
                return {
                    fee = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(FEE))) / 1000000;
                    cumulFee = { cyclesBalance = cumulFee.cyclesBalance; icpBalance = cumulFee.icpBalance; };
                    totalFee = { cyclesBalance = feeBalance.cyclesBalance; icpBalance = feeBalance.icpBalance; };
                    myPortion = ?({
                        cyclesBalance = feeBalance.cyclesBalance * shareWeighted.shareTimeWeighted / _getPoolShareWeighted().shareTimeWeighted;
                        icpBalance = feeBalance.icpBalance * shareWeighted.shareTimeWeighted / _getPoolShareWeighted().shareTimeWeighted;
                    });
                };
            };
        };
    };
    public query func txnRecord(_txid: Txid) : async (txn: ?TxnRecord){
        return _getTxnRecord(_txid);
    };
    /// returns txn record. It's an update method that will try to find txn record in the DRC205 canister if the record does not exist in this canister.
    public shared func txnRecord2(_txid: Txid) : async (txn: ?TxnRecord){
        let drc205: DRC205.Self = actor(STORAGE_CANISTER);
        var step: Nat = 0;
        func _getTxn(_app: Principal, _txid: Txid) : async ?TxnRecord{
            switch(await drc205.bucket(_app, _txid, step, null)){
                case(?(bucketId)){
                    let bucket: DRC205.Bucket = actor(Principal.toText(bucketId));
                    switch(await bucket.txn(_app, _txid)){
                        case(?(txn, time)){ return ?txn; };
                        case(_){
                            step += 1;
                            return await _getTxn(_app, _txid);
                        };
                    };
                };
                case(_){ return null; };
            };
        };
        switch(_getTxnRecord(_txid)){
            case(?(txn)){ return ?txn; };
            case(_){
                return await _getTxn(Principal.fromActor(this), _txid);
            };
        };
    };
    public query func lastTxids(_account: ?Address) : async [Txid]{
        switch(_account) {
            case(null){
                return _getGlobalLastTxns();
            };
            case(?(_a)){
                let account = _getAccountId(_a);
                return _getLastTxns(account);
            };
        }
    };
    public query func getEvents(_account: ?Address) : async [TxnRecord]{
        switch(_account) {
            case(null){
                var i: Nat = 0;
                return Array.chain(_getGlobalLastTxns(), func (value:Txid): [TxnRecord]{
                    if (i < MAX_CACHE_NUMBER_PER){
                        i += 1;
                        switch(_getTxnRecord(value)){
                            case(?(r)){ return [r]; };
                            case(_){ return []; };
                        };
                    }else{ return []; };
                });
            };
            case(?(_a)){
                let account = _getAccountId(_a);
                return Array.chain(_getLastTxns(account), func (value:Txid): [TxnRecord]{
                    switch(_getTxnRecord(value)){
                        case(?(r)){ return [r]; };
                        case(_){ return []; };
                    };
                });
            };
        }
    };
    public query func count(_account: ?Address) : async Nat{
        switch (_account){
            case(?(account)){ return _getNonce(_getAccountId(account)); };
            case(_){ return index; };
        };
    };
    public shared(msg) func add(_account: Address, _nonce: ?Nonce, _data: ?Data) : async TxnResult{  
        assert(_notPaused());
        let caller = _getAccountIdFromPrincipal(msg.caller, null); // cycles wallet
        let account = _getAccountId(_account);
        if (not(_checkNonce(caller, _nonce))){ 
            return #err({code=#NonceError; message="Nonce error! The nonce should be "#Nat.toText(_getNonce(caller))}); 
        };
        let icpBalance = await _getIcpBalance(_getDepositAccount(account));
        if (icpBalance < MIN_ICP_E8S+Nat64.toNat(ICP_FEE)){
            return #err({code=#InvalidIcpAmout; message="Invalid ICP amount."});
        };
        var icpAmount = Nat.sub(icpBalance, Nat64.toNat(ICP_FEE));
        if (icpAmount > ICP_LIMIT){
            icpAmount := ICP_LIMIT;
        };
        let cyclesAvailable = Cycles.available();
        if (cyclesAvailable < MIN_CYCLES){
            return #err({code=#InvalidCyclesAmout; message="Invalid cycles amount."});
        };
        var cyclesAmount = cyclesAvailable;
        if (cyclesAmount > CYCLES_LIMIT){
            cyclesAmount := CYCLES_LIMIT;
        };
        if (k > 0){
            let testCyclesAmount = poolCycles * icpAmount / poolIcp;
            if (testCyclesAmount < cyclesAmount){
                cyclesAmount := testCyclesAmount;
            }else if (testCyclesAmount > cyclesAmount){
                icpAmount := poolIcp * cyclesAmount / poolCycles;
            };
        };
        // begin operation
        let res = await _sendIcpFromSA(account, icpBalance);
        switch(res){
            case(#Err(e)){ return #err({code=#IcpTransferException; message="ICP Transfer Exception."}); };
            case(_){};
        };
        let accept = Cycles.accept(cyclesAmount);
        _putCyclesTransferLog(ctIndex, msg.caller, Principal.fromActor(this), accept, #Success);
        if (accept < cyclesAmount){
            inProgress := List.push((msg.caller, accept, account, icpBalance), inProgress); // fallback cycles & icp
            return #err({code=#UndefinedError; message="Accepting cycles error."});
        };
        if (icpBalance > icpAmount + Nat64.toNat(ICP_FEE)*2){
            inProgress := List.push((msg.caller, 0, account, Nat.sub(icpBalance, icpAmount+Nat64.toNat(ICP_FEE))), inProgress);
        };
        _addLiquidity(cyclesAmount, icpAmount);
        let shareAmount = _calcuShare(cyclesAmount, icpAmount);
        _updatePoolShare(poolShare + shareAmount);
        let shareBalance = _getShare(account).0;
        _updateShare(account, shareBalance + shareAmount);
        // insert record
        let txid = _getTxid(caller);
        var txn: TxnRecord = {
            txid = txid;
            msgCaller = null;
            caller = caller;
            operation = #AddLiquidity;
            account = account;
            cyclesWallet = ?msg.caller;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #DebitRecord(cyclesAmount);
            token1Value = #DebitRecord(icpAmount);
            fee = {token0Fee = 0; token1Fee = 0; };
            shares = #Mint(shareAmount);
            time = Time.now();
            index = index;
            nonce = _getNonce(caller);
            orderType = #AMM;
            details = [];
            data = _data;
        };
        _addNonce(caller);
        _insertTxnRecord(txn);
        let f = _withdraw(); //refund
        // push storeRecords
        storeRecords := List.push((txid, 0), storeRecords);
        // records storage
        let store = _drc205Store();
        return #ok({ txid = txid; cycles = #DebitRecord(cyclesAmount); icpE8s = #DebitRecord(icpAmount); shares = #Mint(shareAmount); });
    };
    public shared(msg) func remove(_shares: ?Shares, _cyclesWallet: CyclesWallet, _nonce: ?Nonce, _sa: ?Sa, _data: ?Data) : async TxnResult { // "_share=null" means remove ALL liquidity
        assert(_notPaused());
        let caller = _getAccountIdFromPrincipal(msg.caller, _sa);
        if (not(_checkNonce(caller, _nonce))){ 
            return #err({code=#NonceError; message="Nonce error! The nonce should be "#Nat.toText(_getNonce(caller))}); 
        };
        var cyclesAmount: Nat = 0;
        var icpAmount: Nat = 0;
        var shareAmount: Nat = 0;
        var shareBalance = _getShare(caller).0;
        switch(_shares) {
            case(null){
                shareAmount := shareBalance;
            };
            case(?(share)){
                shareAmount := share;
            };
        };
        if (shareAmount > shareBalance){
            return #err({code=#InsufficientShares; message="Insufficient shares balance."});
        };
        cyclesAmount := _shareToAmount(shareAmount).cycles;
        icpAmount := _shareToAmount(shareAmount).icp;
        if (icpAmount < MIN_ICP_E8S){
            return #err({code=#InvalidIcpAmout; message="InvalidIcp ICP amount."});
        };
        if (cyclesAmount < MIN_CYCLES){
            return #err({code=#InvalidCyclesAmout; message="Invalid cycles amount."});
        };
        // begin operation
        inProgress := List.push((_cyclesWallet, cyclesAmount, caller, icpAmount), inProgress);
        _removeLiquidity(cyclesAmount, icpAmount);
        _updatePoolShare(poolShare - shareAmount);
        _updateShare(caller, shareBalance - shareAmount);
        // insert record
        let txid = _getTxid(caller);
        var txn: TxnRecord = {
            txid = txid;
            msgCaller = null;
            caller = caller;
            operation = #RemoveLiquidity;
            account = caller;
            cyclesWallet = ?_cyclesWallet;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #CreditRecord(cyclesAmount);
            token1Value = #CreditRecord(_subIcpFee(icpAmount));
            fee = {token0Fee = 0; token1Fee = 0; };
            shares = #Burn(shareAmount);
            time = Time.now();
            index = index;
            nonce = _getNonce(caller);
            orderType = #AMM;
            details = [];
            data = _data;
        };
        _addNonce(caller);
        _insertTxnRecord(txn);
        let f = _withdraw();
        // push storeRecords
        storeRecords := List.push((txid, 0), storeRecords);
        // records storage
        let store = _drc205Store();
        return #ok({ txid = txid; cycles = #CreditRecord(cyclesAmount); icpE8s = #CreditRecord(_subIcpFee(icpAmount)); shares = #Burn(shareAmount); });
    };
    public shared(msg) func cyclesToIcp(_account: Address, _nonce: ?Nonce, _data: ?Data): async TxnResult {
        assert(_notPaused());
        let caller = _getAccountIdFromPrincipal(msg.caller, null);
        let account = _getAccountId(_account);
        if (not(_checkNonce(caller, _nonce))){ 
            return #err({code=#NonceError; message="Nonce error! The nonce should be "#Nat.toText(_getNonce(caller))}); 
        };
        if (k == 0){
            return #err({code=#PoolIsEmpty; message="Pool is Empty."});
        };
        var cyclesAvailable = Cycles.available();
        if (cyclesAvailable > CYCLES_LIMIT){
            cyclesAvailable := CYCLES_LIMIT;
        };
        if (cyclesAvailable < MIN_CYCLES){
            return #err({code=#InvalidCyclesAmout; message="Invalid cycles amount."});
        };
        let newPoolCycles = poolCycles + cyclesAvailable;
        let newPoolIcp = k / newPoolCycles;
        var outIcpAmount = Nat.sub(poolIcp, newPoolIcp);
        if (_volatility(newPoolCycles, newPoolIcp) > 20){
            return #err({code=#UnacceptableVolatility; message="Unacceptable volatility."});
        };
        // begin operation
        let inCyclesAmount = Cycles.accept(cyclesAvailable);
        _putCyclesTransferLog(ctIndex, msg.caller, Principal.fromActor(this), inCyclesAmount, #Success);
        if (inCyclesAmount < cyclesAvailable){
            inProgress := List.push((msg.caller, inCyclesAmount, account, 0), inProgress); // fallback cycles
            return #err({code=#UndefinedError; message="Accepting cycles error."});
        };
        _updateLiquidity(newPoolCycles, newPoolIcp);
        _updateVol(account, inCyclesAmount, outIcpAmount);
        let icpFee = outIcpAmount * FEE / 1000000;
        _chargeFee(0, icpFee);
        outIcpAmount -= icpFee;
        inProgress := List.push((msg.caller, 0, account, outIcpAmount), inProgress);// send icp
        // insert record
        let txid = _getTxid(caller);
        var txn: TxnRecord = {
            txid = txid;
            msgCaller = null;
            caller = caller;
            operation = #Swap;
            account = account;
            cyclesWallet = ?msg.caller;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #DebitRecord(inCyclesAmount);
            token1Value = #CreditRecord(_subIcpFee(outIcpAmount));
            fee = {token0Fee = 0; token1Fee = icpFee; };
            shares = #NoChange;
            time = Time.now();
            index = index;
            nonce = _getNonce(caller);
            orderType = #AMM;
            details = [];
            data = _data;
        };
        _addNonce(caller);
        _insertTxnRecord(txn);
        let f = _withdraw();
        // push storeRecords
        storeRecords := List.push((txid, 0), storeRecords);
        // records storage
        let store = _drc205Store();
        return #ok({ txid = txid; cycles = #DebitRecord(inCyclesAmount); icpE8s = #CreditRecord(_subIcpFee(outIcpAmount)); shares = #NoChange; });
    };
    public shared(msg) func icpToCycles(_icpE8s: IcpE8s, _cyclesWallet: CyclesWallet, _nonce: ?Nonce, _sa: ?Sa, _data: ?Data): async TxnResult {
        assert(_notPaused());
        let caller = _getAccountIdFromPrincipal(msg.caller, _sa);
        if (not(_checkNonce(caller, _nonce))){ 
            return #err({code=#NonceError; message="Nonce error! The nonce should be "#Nat.toText(_getNonce(caller))}); 
        };
        if (k == 0){
            return #err({code=#PoolIsEmpty; message="Pool is Empty."});
        };
        var inIcpBalance = await _getIcpBalance(_getDepositAccount(caller));
        if (_icpE8s > inIcpBalance){
            return #err({code=#InvalidIcpAmout; message="Invalid ICP amount."});
        };
        if (_icpE8s < MIN_ICP_E8S+Nat64.toNat(ICP_FEE)){
            return #err({code=#InvalidIcpAmout; message="Invalid ICP amount."});
        };
        var inIcpAmount = Nat.sub(_icpE8s, Nat64.toNat(ICP_FEE));
        if (inIcpAmount > ICP_LIMIT){
            inIcpAmount := ICP_LIMIT;
        };
        var newPoolIcp = poolIcp + inIcpAmount;
        var newPoolCycles = k / newPoolIcp;
        if (_volatility(newPoolCycles, newPoolIcp) > 20){
            return #err({code=#UnacceptableVolatility; message="Unacceptable volatility."});
        };
        // begin operation
        let res = await _sendIcpFromSA(caller, inIcpBalance);
        switch(res){
            case(#Err(e)){ return #err({code=#IcpTransferException; message="ICP Transfer Exception."}); };
            case(_){};
        };
        newPoolIcp := poolIcp + inIcpAmount;
        newPoolCycles := k / newPoolIcp;
        var outCyclesAmount = Nat.sub(poolCycles, newPoolCycles);
        _updateLiquidity(newPoolCycles, newPoolIcp);
        _updateVol(caller, outCyclesAmount, inIcpAmount);
        let cyclesFee = outCyclesAmount * FEE / 1000000;
        _chargeFee(cyclesFee, 0);
        outCyclesAmount -= cyclesFee;
        var reFund: Nat = 0;
        if (Nat.sub(inIcpBalance, inIcpAmount) > Nat64.toNat(ICP_FEE)*2){
            reFund := Nat.sub(inIcpBalance, inIcpAmount) - Nat64.toNat(ICP_FEE);
        };
        inProgress := List.push((_cyclesWallet, outCyclesAmount, caller, reFund), inProgress);
        // insert record
        let txid = _getTxid(caller);
        var txn: TxnRecord = {
            txid = txid;
            msgCaller = null;
            caller = caller;
            operation = #Swap;
            account = caller;
            cyclesWallet = ?_cyclesWallet;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #CreditRecord(outCyclesAmount);
            token1Value = #DebitRecord(inIcpAmount);
            fee = {token0Fee = cyclesFee; token1Fee = 0; };
            shares = #NoChange;
            time = Time.now();
            index = index;
            nonce = _getNonce(caller);
            orderType = #AMM;
            details = [];
            data = _data;
        };
        _addNonce(caller);
        _insertTxnRecord(txn);
        let f = _withdraw();
        // push storeRecords
        storeRecords := List.push((txid, 0), storeRecords);
        // records storage
        let store = _drc205Store();
        return #ok({ txid = txid; cycles = #CreditRecord(outCyclesAmount); icpE8s = #DebitRecord(inIcpAmount); shares = #NoChange; });
    };
    public shared(msg) func claim(_cyclesWallet: CyclesWallet, _nonce: ?Nonce, _sa: ?Sa, _data: ?Data) : async TxnResult {
        assert(_notPaused());
        let caller = _getAccountIdFromPrincipal(msg.caller, _sa);
        if (not(_checkNonce(caller, _nonce))){ 
            return #err({code=#NonceError; message="Nonce error! The nonce should be "#Nat.toText(_getNonce(caller))}); 
        };
        if (poolShare == 0){
            return #err({code=#PoolIsEmpty; message="Pool is Empty."});
        };
        // begin operation
        _updatePoolShare(poolShare);
        let (share, shareWeighted, cumulShareWeighted) = _getShare(caller);
        let outCyclesAmount = feeBalance.cyclesBalance * shareWeighted.shareTimeWeighted / _getPoolShareWeighted().shareTimeWeighted;
        let outIcpAmount = feeBalance.icpBalance * shareWeighted.shareTimeWeighted / _getPoolShareWeighted().shareTimeWeighted;
        shares := Trie.put(shares, keyb(caller), Blob.equal, (share, {
            shareTimeWeighted = 0;
            updateTime = _now();
        }, cumulShareWeighted)).0;
        feeBalance.cyclesBalance -= outCyclesAmount;
        feeBalance.icpBalance -= outIcpAmount;
        inProgress := List.push((_cyclesWallet, outCyclesAmount, caller, outIcpAmount), inProgress);
        // insert record
        let txid = _getTxid(caller);
        var txn: TxnRecord = {
            txid = txid;
            msgCaller = null;
            caller = caller;
            operation = #Claim;
            account = caller;
            cyclesWallet = ?_cyclesWallet;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #CreditRecord(outCyclesAmount);
            token1Value = #CreditRecord(_subIcpFee(outIcpAmount));
            fee = {token0Fee = 0; token1Fee = 0; };
            shares = #NoChange;
            time = Time.now();
            index = index;
            nonce = _getNonce(caller);
            orderType = #AMM;
            details = [];
            data = _data;
        };
        _addNonce(caller);
        _insertTxnRecord(txn);
        let f = _withdraw(); // send cycles and icp
        // push storeRecords
        storeRecords := List.push((txid, 0), storeRecords);
        // records storage
        let store = _drc205Store();
        return #ok({ txid = txid; cycles = #CreditRecord(outCyclesAmount); icpE8s = #CreditRecord(_subIcpFee(outIcpAmount)); shares = #NoChange; });
    };

    /* 
    * Owner's Management
    */
    public shared(msg) func getIcpTransferLogs(_from: ?Nat) : async (logs: [(Nat, IcpTransferLog)], isEnd: Bool){  // page_size = 50
        assert(_onlyOwner(msg.caller));
        var from = Option.get(_from, Nat.sub(Nat.max(Nat64.toNat(itIndex),1), 1));
        var isEnd: Bool = false;
        if (from >= Nat64.toNat(itIndex)) { from := Nat.sub(Nat.max(Nat64.toNat(itIndex),1), 1); };
        var res:[(Nat, IcpTransferLog)] = [];
        var i = from;
        while(not(isEnd) and i >= Nat.sub(Nat.max(from+1,50), 50)){
            switch(Trie.get(icpTransferLogs, keyn(i), Nat.equal)){
                case(?(icpTransferLog)){ res := Array.append(res, [(i, icpTransferLog)]); };
                case(_){ isEnd := true; };
            };
            if (i > 0) { i -= 1; };
            if (i == 0) { isEnd := true; };
        };
        return (res, isEnd);
    };
    public shared(msg) func getCyclesTransferLogs(_from: ?Nat) : async (logs: [(Nat, CyclesTransferLog)], isEnd: Bool){  // page_size = 50
        assert(_onlyOwner(msg.caller));
        var from = Option.get(_from, Nat.sub(Nat.max(Nat64.toNat(ctIndex),1), 1));
        var isEnd: Bool = false; 
        if (from >= Nat64.toNat(ctIndex)) { from := Nat.sub(Nat.max(Nat64.toNat(ctIndex),1), 1); };
        var res:[(Nat, CyclesTransferLog)] = [];
        var i = from;
        while(not(isEnd) and i >= Nat.sub(Nat.max(from+1,50), 50)){
            switch(Trie.get(cyclesTransferLogs, keyn(i), Nat.equal)){
                case(?(cyclesTransferLog)){ res := Array.append(res, [(i, cyclesTransferLog)]); };
                case(_){ isEnd := true; };
            };
            if (i > 0) { i -= 1; };
            if (i == 0) { isEnd := true; };
        };
        return (res, isEnd);
    };
    public shared(msg) func getErrors(_from: ?Nat) : async (errors: [(Nat, ErrorLog)], isEnd: Bool){  // page_size = 50
        assert(_onlyOwner(msg.caller));
        var from = Option.get(_from, Nat.sub(Nat.max(errorIndex,1), 1));
        var isEnd: Bool = false;
        if (from >= errorIndex) { from := Nat.sub(Nat.max(errorIndex,1), 1); };
        var res:[(Nat, ErrorLog)] = [];
        var i = from;
        while(not(isEnd) and i >= Nat.sub(Nat.max(from+1,50), 50)){
            switch(Trie.get(errors, keyn(i), Nat.equal)){
                case(?(error)){ res := Array.append(res, [(i, error)]); };
                case(_){ isEnd := true; };
            };
            if (i > 0) { i -= 1; };
            if (i == 0) { isEnd := true; };
        };
        return (res, isEnd);
    };
    public shared(msg) func getHandledErrorHistory(_page: ?Nat/*start from 1*/) : async (history: [(Nat, ErrorLog, ErrorAction, ?CyclesWallet)], page: Nat, total: Nat, isEnd: Bool){  // page_size = 50
        assert(_onlyOwner(msg.caller));
        let pageSize: Nat = 50;
        let page = Nat.max(Option.get(_page, 1),1);
        let from = pageSize * Nat.sub(page, 1);
        let to = Nat.sub(pageSize * page, 1);
        var isEnd: Bool = false;
        let arr = List.toArray(errorHistory);
        let len = arr.size();
        let res = Tools.slice(arr, from, ?to);
        if (to >= len) { isEnd := true; };
        return (res, page, len, isEnd);
    };
    public shared(msg) func handleError(_index: Nat, action: ErrorAction, _replaceCyclesWallet: ?CyclesWallet) : async Bool{
        switch(Trie.get(errors, keyn(_index), Nat.equal)){
            case(?(error)){
                switch(error){
                    case(#IcpSaToMain(log)){
                        if (action == #fallback){ // fallback
                            let res = await _sendIcpFromMA(log.debit.1, log.debit.2);
                            switch(res){
                                case(#Ok(blockheight)){};
                                case(#Err(e)){ throw Error.reject("Icp fallback error!"); };
                            };
                            //_putIcpTransferLog(log.debit.0, log.debit.1, _getMainAccount(), log.debit.2, #Fallback);
                        };
                    };
                    case(#Withdraw(log)){
                        if (action == #resendIcpCycles){ // resend
                            var cyclesWallet = log.credit.0;
                            switch(_replaceCyclesWallet){
                                case(?(wallet)){ cyclesWallet := wallet; };
                                case(_){};
                            };
                            inProgress := List.push((cyclesWallet, log.credit.1, log.credit.2, log.credit.3), inProgress);
                            let f = _withdraw();
                        }else if (action == #resendCycles){ // resend
                            var cyclesWallet = log.credit.0;
                            switch(_replaceCyclesWallet){
                                case(?(wallet)){ cyclesWallet := wallet; };
                                case(_){};
                            };
                            inProgress := List.push((cyclesWallet, log.credit.1, log.credit.2, 0), inProgress);
                            let f = _withdraw();
                        }else if (action == #resendIcp){ // resend
                            inProgress := List.push((log.credit.0, 0, log.credit.2, log.credit.3), inProgress);
                            let f = _withdraw();
                        };
                    };
                };
                errors := Trie.remove(errors, keyn(_index), Nat.equal).0;
                errorHistory := List.push((_index, error, action, _replaceCyclesWallet), errorHistory);
                let historyLen = List.size(errorHistory);
                var hi: Nat = 0;
                if (historyLen > 1500){
                    errorHistory := List.filter(errorHistory, func (v:(Nat, ErrorLog, ErrorAction, ?CyclesWallet)):Bool{ hi += 1; hi <= 1000 });
                };
            };
            case(_){ return false; };
        };
        return true;
    };
    // config   Note: FEE is ?/1000000
    public shared(msg) func config(config: Config) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        MIN_CYCLES := Option.get(config.MIN_CYCLES, MIN_CYCLES);
        MIN_ICP_E8S := Option.get(config.MIN_ICP_E8S, MIN_ICP_E8S);
        ICP_FEE := Option.get(config.ICP_FEE, ICP_FEE);
        FEE := Option.get(config.FEE, FEE);
        ICP_LIMIT := Option.get(config.ICP_LIMIT, ICP_LIMIT);
        CYCLES_LIMIT := Option.get(config.CYCLES_LIMIT, CYCLES_LIMIT);
        MAX_CACHE_TIME := Option.get(config.MAX_CACHE_TIME, MAX_CACHE_TIME);
        MAX_CACHE_NUMBER_PER := Option.get(config.MAX_CACHE_NUMBER_PER, MAX_CACHE_NUMBER_PER);
        STORAGE_CANISTER := Option.get(config.STORAGE_CANISTER, STORAGE_CANISTER);
        MAX_STORAGE_TRIES := Option.get(config.MAX_STORAGE_TRIES, MAX_STORAGE_TRIES);
        return true;
    };
    public query func getOwner() : async Principal{  
        return owner;
    };
    public shared(msg) func changeOwner(_newOwner: Principal) : async Bool{  
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
        return true;
    };
    public shared(msg) func setPause(_pause: Bool) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        pause := _pause;
        return true;
    };
    /// canister memory
    public query func getMemory() : async (Nat,Nat,Nat,Nat32){
        return (Prim.rts_memory_size(), Prim.rts_heap_size(), Prim.rts_total_allocation(),Prim.stableMemorySize());
    };
    /// canister cycles
    public query func getCycles() : async Nat{
        return return Cycles.balance();
    };

    // DRC207 ICMonitor
    /// DRC207 support
    public func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = true;
            monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai"); };
            cycles_receivable = false;
            timer = { enable = false; interval_seconds = null; }; 
        };
    };
    /// canister_status
    public func canister_status() : async DRC207.canister_status {
        let ic : DRC207.IC = actor("aaaaa-aa");
        await ic.canister_status({ canister_id = Principal.fromActor(this) });
    };
    /// receive cycles
    // public func wallet_receive(): async (){
    //     let amout = Cycles.available();
    //     let accepted = Cycles.accept(amout);
    // };
    /// timer tick
    // public func timer_tick(): async (){
    //     //
    // };
}