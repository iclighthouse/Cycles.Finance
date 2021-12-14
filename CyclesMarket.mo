/**
 * Module     : CyclesMarket.mo
 * Author     : ICLight.house Team
 * License    : GNU General Public License v3.0
 * Stability  : Experimental
 * Canister   : ium3d-eqaaa-aaaak-aab4q-cai
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
import Monitee "./lib/Monitee";

shared(installMsg) actor class CyclesMarket() = this {
    type Timestamp = T.Timestamp;  //seconds
    type AccountId = T.AccountId;  //Blob
    type ShareWeighted = T.ShareWeighted;
    type CumulShareWeighted = T.CumulShareWeighted;
    type Vol = T.Vol;
    type PriceWeighted = T.PriceWeighted;
    type FeeBalance = T.FeeBalance;
    type Liquidity = T.Liquidity;
    type FeeStatus = T.FeeStatus;
    type ErrorLog = T.ErrorLog;
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
    private stable var MAX_CACHE_TIME: Nat = 3 * 30 * 24 * 3600; //seconds  3 months
    private stable var MAX_CACHE_NUMBER_PER: Nat = 20;
    private stable var STORAGE_CANISTER: Text = "";
    private stable var MAX_STORAGE_TRIES: Nat = 2; 

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
    private stable var transferIndex: Nat64 = 0;  //start 1

    private stable var shares: Trie.Trie<Principal, (Nat, ShareWeighted, CumulShareWeighted)> = Trie.empty(); 
    private stable var vols: Trie.Trie<Principal, Vol> = Trie.empty(); 
    private stable var inProgress = List.nil<(cyclesWallet: Principal, cycles: Nat, icpAccount: Principal, icp: Nat)>();
    private stable var errors: Trie.Trie<Nat, ErrorLog> = Trie.empty(); 
    private stable var errorIndex: Nat = 0;
    private stable var nonces: Trie.Trie<Principal, Nat> = Trie.empty(); 
    private stable var txnRecords: Trie.Trie<Txid, TxnRecord> = Trie.empty();
    private stable var globalTxns = Deque.empty<(Txid, Time.Time)>();
    private stable var globalLastTxns = Deque.empty<Txid>();
    private stable var index: Nat = 0;
    // TODO logs storage
    private stable var accountLastTxns: Trie.Trie<Principal, Deque.Deque<Txid>> = Trie.empty();
    //private stable var storeRecords = List.nil<(Txid, Nat)>();
    //private stable var top100Vol: [(Principal, Nat)] = []; //token1
    //private stable var top100Liquidity: [(Principal, Nat)] = []; //share 
    
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

    private func _getNonce(_p: Principal): Nat{
        switch(Trie.get(nonces, keyp(_p), Principal.equal)){
            case(?(v)){
                return v;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _addNonce(_p: Principal): (){
        var n = _getNonce(_p);
        nonces := Trie.put(nonces, keyp(_p), Principal.equal, n+1).0;
        index += 1;
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
    private func _getUserAccount(_p: Principal) : AccountId{
        return Blob.fromArray(Tools.principalToAccount(_p, null));
    };
    private func _getDepositAccount(_p: Principal) : AccountId{
        let main = Principal.fromActor(this);
        let sa = Blob.toArray(Principal.toBlob(_p));
        return Blob.fromArray(Tools.principalToAccount(main, ?sa));
    };
    private func _getIcpBalance(_a: AccountId) : async Nat{ //e8s
        let res = await ledger.account_balance({
            account = _a;
        });
        return Nat64.toNat(res.e8s);
    };
    private func _sendIcpFromMA(_to: AccountId, _value: Nat) : async Ledger.TransferResult{
        var amount = Nat64.fromNat(_value);
        amount := if (amount > ICP_FEE){ amount - ICP_FEE } else { 0 };
        let res = await ledger.transfer({
            to = _to;
            fee = { e8s = ICP_FEE; };
            memo = transferIndex;
            from_subaccount = null;
            created_at_time = ?{timestamp_nanos = Nat64.fromIntWrap(Time.now())};
            amount = { e8s = amount };
        });
        // switch(res){
        //     case(#Err(e)){ assert(false);};
        //     case(_){};
        // };
        transferIndex += 1;
        return res;
    };
    private func _sendIcpFromSA(_from: Principal, _to: AccountId, _value: Nat) : async Ledger.TransferResult{
        var amount = Nat64.fromNat(_value);
        amount := if (amount > ICP_FEE){ amount - ICP_FEE } else { 0 };
        let res = await ledger.transfer({
            to = _to;
            fee = { e8s = ICP_FEE; };
            memo = transferIndex;
            from_subaccount = ?_getSA(Principal.toBlob(_from));
            created_at_time = null;
            amount = { e8s = amount };
        });
        // switch(res){
        //     case(#Err(e)){ assert(false);};
        //     case(_){};
        // };
        transferIndex += 1;
        return res;
    };
    private func _subIcpFee(_icpE8s: Nat) : Nat{
        if (_icpE8s > Nat64.toNat(ICP_FEE)){
            return Nat.sub(_icpE8s, Nat64.toNat(ICP_FEE));
        }else {
            return 0;
        };
    };
    private func _addLiquidity(_addCycles: Nat, _addIcp: Nat) : (){ 
        var now = _now();
        if (now < priceWeighted.updateTime){ now := priceWeighted.updateTime; };
        let oldPoolCycles = poolCycles;
        let oldPoolIcp = poolIcp;
        poolCycles += _addCycles;
        poolIcp += _addIcp;
        k := poolCycles * poolIcp; 
        priceWeighted := {
            cyclesTimeWeighted = priceWeighted.cyclesTimeWeighted + oldPoolCycles * Nat.sub(now, priceWeighted.updateTime);
            icpTimeWeighted = priceWeighted.icpTimeWeighted + oldPoolIcp * Nat.sub(now, priceWeighted.updateTime);
            updateTime = now;
        };
        //if (poolShare > 0 ){ _updateUnitValue(); };
    };
    private func _removeLiquidity(_subCycles: Nat, _subIcp: Nat) : (){
        var now = _now();
        if (now < priceWeighted.updateTime){ now := priceWeighted.updateTime; };
        let oldPoolCycles = poolCycles;
        let oldPoolIcp = poolIcp;
        poolCycles -= _subCycles;
        poolIcp -= _subIcp;
        k := poolCycles * poolIcp; 
        priceWeighted := {
            cyclesTimeWeighted = priceWeighted.cyclesTimeWeighted + oldPoolCycles * Nat.sub(now, priceWeighted.updateTime);
            icpTimeWeighted = priceWeighted.icpTimeWeighted + oldPoolIcp * Nat.sub(now, priceWeighted.updateTime);
            updateTime = now;
        };
        //if (poolShare > 0 ){ _updateUnitValue(); };
    };
    private func _updateLiquidity(_newCycles: Nat, _newIcp: Nat) : (){
        var now = _now();
        if (now < priceWeighted.updateTime){ now := priceWeighted.updateTime; };
        let oldPoolCycles = poolCycles;
        let oldPoolIcp = poolIcp;
        poolCycles := _newCycles;
        poolIcp := _newIcp;
        k := poolCycles * poolIcp; 
        priceWeighted := {
            cyclesTimeWeighted = priceWeighted.cyclesTimeWeighted + oldPoolCycles * Nat.sub(now, priceWeighted.updateTime);
            icpTimeWeighted = priceWeighted.icpTimeWeighted + oldPoolIcp * Nat.sub(now, priceWeighted.updateTime);
            updateTime = now;
        };
        if (poolShare > 0 ){ _updateUnitValue(); };
    };
    private func _updateUnitValue() : (){
        unitValue := poolIcp*1000000 / poolShare;
    };
    private func _calcuShare(_cyclesAmout: Nat, _icpAmout: Nat) : Nat{
        return _icpAmout*1000000 / unitValue;
    };
    private func _shareToAmount(_share: Nat) : {cycles: Nat; icp: Nat}{
        return {
            cycles = poolCycles * _share * unitValue / 1000000 / poolIcp; 
            icp = _share * unitValue / 1000000;
        };
    };
    private func _updatePoolShare(_newShare: Nat) : (){
        var now = _now();
        if (now < poolShareWeighted.updateTime){ now := poolShareWeighted.updateTime; };
        let oldPoolShare = poolShare;
        poolShare := _newShare;
        poolShareWeighted := {
            shareTimeWeighted = poolShareWeighted.shareTimeWeighted + oldPoolShare * Nat.sub(now, poolShareWeighted.updateTime);
            updateTime = now;
        };
    };
    private func _getShare(_p: Principal) : Nat{
        switch(Trie.get(shares, keyp(_p), Principal.equal)){
            case(?(share)){
                return share.0;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _getShareWeighted(_p: Principal) : ShareWeighted{
        switch(Trie.get(shares, keyp(_p), Principal.equal)){
            case(?(share)){
                return share.1;
            };
            case(_){
                return {shareTimeWeighted = 0; updateTime =0; };
            };
        };
    };
    private func _getCumulShareWeighted(_p: Principal) : CumulShareWeighted{
        switch(Trie.get(shares, keyp(_p), Principal.equal)){
            case(?(share)){
                return share.2;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _updateShare(_p: Principal, _newShare: Nat) : (){
        var now = _now();
        switch(Trie.get(shares, keyp(_p), Principal.equal)){
            case(?(share)){
                if (now < share.1.updateTime){ now := share.1.updateTime; };
                let oldUserShare = share.0;
                let shareWeighted: ShareWeighted = {
                    shareTimeWeighted = share.1.shareTimeWeighted + oldUserShare * Nat.sub(now, share.1.updateTime);
                    updateTime = now;
                };
                let newCumulShareWeighted = share.2 + oldUserShare * Nat.sub(now, share.1.updateTime);
                shares := Trie.put(shares, keyp(_p), Principal.equal, (_newShare, shareWeighted, newCumulShareWeighted)).0;
            };
            case(_){
                shares := Trie.put(shares, keyp(_p), Principal.equal, (_newShare, {
                    shareTimeWeighted = 0;
                    updateTime = now;
                }, 0)).0;
            };
        };
    };
    private func _getVol(_p: Principal) : Vol{
        switch(Trie.get(vols, keyp(_p), Principal.equal)){
            case(?(vol)){
                return vol;
            };
            case(_){
                return { swapCyclesVol = 0; swapIcpVol = 0;};
            };
        };
    };
    private func _updateVol(_p: Principal, _addCyclesVol: Nat, _addIcpVol: Nat) : (){
        totalVol := {
            swapCyclesVol = totalVol.swapCyclesVol + _addCyclesVol;
            swapIcpVol = totalVol.swapIcpVol + _addIcpVol;
        };
        switch(Trie.get(vols, keyp(_p), Principal.equal)){
            case(?(vol)){
                let newVol = {
                    swapCyclesVol = vol.swapCyclesVol + _addCyclesVol;
                    swapIcpVol = vol.swapIcpVol + _addIcpVol;
                };
                vols := Trie.put(vols, keyp(_p), Principal.equal, newVol).0;
            };
            case(_){
                vols := Trie.put(vols, keyp(_p), Principal.equal, {
                    swapCyclesVol = _addCyclesVol;
                    swapIcpVol = _addIcpVol;
                }).0;
            };
        };
    };
    private func _withdraw() : async (){
        var item = List.pop(inProgress);
        while (Option.isSome(item.0)){
            switch(item.0){
                case(?(cyclesWallet, cycles, icpAccount, icp)){
                    var temp = (cyclesWallet, 0, icpAccount, 0);
                    if (cycles >= MIN_CYCLES){
                        var mainBalance = Cycles.balance();
                        try{
                            let wallet: CyclesWallet.Self = actor(Principal.toText(cyclesWallet));
                            Cycles.add(cycles);
                            await wallet.wallet_receive();
                        } catch(e){ 
                            var mainBalance2 = Cycles.balance();
                            if (mainBalance < MIN_CYCLES or Nat.sub(mainBalance, mainBalance2) < cycles){
                                temp := (temp.0, cycles, temp.2, temp.3);
                            };
                        };
                    };
                    if (icp >= MIN_ICP_E8S){
                        var mainBalance: Nat = 0;
                        try{
                            mainBalance := Nat64.toNat((await ledger.account_balance({account = _getMainAccount()})).e8s);
                            let res = await _sendIcpFromMA(_getUserAccount(icpAccount), icp);
                            switch(res){
                                case(#Err(e)){ throw Error.reject("ICP sending error!");};
                                case(_){};
                            };
                        } catch(e){ 
                            var mainBalance2: Nat = 0;
                            try{
                                mainBalance2 := Nat64.toNat((await ledger.account_balance({account = _getMainAccount()})).e8s);
                                if (mainBalance < MIN_ICP_E8S or Nat.sub(mainBalance, mainBalance2) < icp){
                                    temp := (temp.0, temp.1, temp.2, icp);
                                };
                            } catch(e){
                                temp := (temp.0, temp.1, temp.2, icp);
                            };
                        };
                    };
                    if (temp.1 >= MIN_CYCLES or temp.3 >= MIN_ICP_E8S){
                        errors := Trie.put(errors, keyn(errorIndex), Nat.equal, {
                            user = temp.2;
                            withdraw = (temp.0, temp.1, temp.2, temp.3);
                            time = _now();
                        }).0;
                        errorIndex += 1;
                    };
                };
                case(_){};
            };
            item := List.pop(item.1);
            inProgress := item.1;
        };
    };
    private func _chargeFee(_cyclesFee: Nat, _icpFee: Nat) : (){
        feeBalance.cyclesBalance += _cyclesFee*8/10;
        feeBalance.icpBalance += _icpFee;
        cumulFee.cyclesBalance += _cyclesFee*8/10;
        cumulFee.icpBalance += _icpFee;
    };
    private func _volatility(_newPoolCycles: Nat, _newPoolIcp: Nat) : Nat{
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
    private func _generateTxid(_canister: Principal, _caller: Principal, _nonce: Nat): Txid{
        let canister: [Nat8] = Blob.toArray(Principal.toBlob(_canister));
        let caller: [Nat8] = Blob.toArray(Principal.toBlob(_caller));
        let nonce: [Nat8] = Binary.BigEndian.fromNat32(Nat32.fromNat(_nonce));
        let txInfo = Array.append(Array.append(canister, caller), nonce);
        let h224: [Nat8] = SHA224.sha224(txInfo);
        return Blob.fromArray(Array.append(nonce, h224));
    };
    private func _getTxid(_caller: Principal) : Txid{
        //return Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_index)));
        return _generateTxid(Principal.fromActor(this), _caller, _getNonce(_caller))
    };
    private func _getTxnRecord(_txid: Txid): ?TxnRecord{
        return Trie.get(txnRecords, keyb(_txid), Blob.equal);
    };
    private func _insertTxnRecord(_swap: TxnRecord): (){
        var txid = _swap.txid;
        txnRecords := Trie.put(txnRecords, keyb(txid), Blob.equal, _swap).0;
        _pushGlobalTxns(txid);
        _pushLastTxn(_swap.account, txid);
    };
    private func _pushGlobalTxns(_txid: Txid): (){
        // push new txid.
        globalTxns := Deque.pushFront(globalTxns, (_txid, Time.now()));
        globalLastTxns := Deque.pushFront(globalLastTxns, _txid);
        var size = List.size(globalLastTxns.0) + List.size(globalLastTxns.1);
        while (size > MAX_CACHE_NUMBER_PER * 5){
            size -= 1;
            switch (Deque.popBack(globalLastTxns)){
                case(?(q, v)){
                    globalLastTxns := q;
                };
                case(_){};
            };
        };
    };
    private func _getGlobalLastTxns(): [Txid]{
        var l = List.append(globalLastTxns.0, List.reverse(globalLastTxns.1));
        return List.toArray(l);
    };
    private func _getLastTxns(_a: Principal): [Txid]{
        switch(Trie.get(accountLastTxns, keyp(_a), Principal.equal)){
            case(?(swaps)){
                var l = List.append(swaps.0, List.reverse(swaps.1));
                return List.toArray(l);
            };
            case(_){
                return [];
            };
        };
    };
    private func _cleanLastTxns(_a: Principal): (){
        switch(Trie.get(accountLastTxns, keyp(_a), Principal.equal)){
            case(?(swaps)){  
                var txids: Deque.Deque<Txid> = swaps;
                var size = List.size(txids.0) + List.size(txids.1);
                while (size > MAX_CACHE_NUMBER_PER){
                    size -= 1;
                    switch (Deque.popBack(txids)){
                        case(?(q, v)){
                            txids := q;
                            switch(Deque.peekFront(txids)){
                                case(?(v)){};
                                case(_){
                                    accountLastTxns := Trie.remove(accountLastTxns, keyp(_a), Principal.equal).0;
                                };
                            };
                        };
                        case(_){};
                    };
                };
                accountLastTxns := Trie.put(accountLastTxns, keyp(_a), Principal.equal, txids).0;
            };
            case(_){};
        };
    };
    private func _pushLastTxn(_a: Principal, _txid: Txid): (){
        switch(Trie.get(accountLastTxns, keyp(_a), Principal.equal)){
            case(?(q)){
                var txids: Deque.Deque<Txid> = q;
                txids := Deque.pushFront(txids, _txid);
                accountLastTxns := Trie.put(accountLastTxns, keyp(_a), Principal.equal, txids).0;
                _cleanLastTxns(_a);
            };
            case(_){
                var new = Deque.empty<Txid>();
                new := Deque.pushFront(new, _txid);
                accountLastTxns := Trie.put(accountLastTxns, keyp(_a), Principal.equal, new).0;
            };
        };
    };

    /* 
    * Shared Functions
    */
    // public query func getSA(_account: Principal) : async (Blob, Text){
    //     let sa = _getSA(Principal.toBlob(_account));
    //     return (sa, Hex.encode(Blob.toArray(sa)));
    // };
    // public query func getK() : async Nat{
    //     return k;
    // };
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
    public query func getAccountId(_account: Principal) : async Text{
        return Hex.encode(Blob.toArray(_getDepositAccount(_account)));
    };
    public query func liquidity(_account: ?Principal) : async Liquidity{
        let unitIcp = unitValue;
        let unitCycles = unitIcp * poolCycles / poolIcp;
        let unitIcpFloat = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(unitIcp))) / 1000000;
        let unitCyclesFloat = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(unitCycles))) / 1000000;
        switch(_account) {
            case(null){
                return {
                    cycles = poolCycles;
                    icp = {e8s = Nat64.fromNat(poolIcp);};
                    share = poolShare;
                    shareWeighted = poolShareWeighted;
                    cumulShareWeighted = poolShareWeighted.shareTimeWeighted;
                    unitValue = (unitCyclesFloat, unitIcpFloat);
                    vol = totalVol;
                    priceWeighted = priceWeighted;
                    swapCount = Nat64.fromNat(index);
                };
            };
            case(?(account)){
                let share = _getShare(account);
                let shareWeighted = _getShareWeighted(account);
                let vol = _getVol(account);
                return {
                    cycles = poolCycles * share / poolShare;
                    icp = {e8s = Nat64.fromNat(poolIcp * share / poolShare);};
                    share = share;
                    shareWeighted = shareWeighted;
                    cumulShareWeighted = _getCumulShareWeighted(account);
                    unitValue = (unitCyclesFloat, unitIcpFloat);
                    vol = vol;
                    priceWeighted = priceWeighted;
                    swapCount = Nat64.fromNat(_getNonce(account));
                };
            };
        };
    };
    public query func feeStatus(_account: ?Principal) : async FeeStatus{
        switch(_account) {
            case(null){
                return {
                    fee = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(FEE))) / 1000000;
                    cumulFee = { cyclesBalance = cumulFee.cyclesBalance; icpBalance = cumulFee.icpBalance; };
                    totalFee = { cyclesBalance = feeBalance.cyclesBalance; icpBalance = feeBalance.icpBalance; };
                    myAllocable = null;
                };
            };
            case(?(account)){
                let shareWeighted = _getShareWeighted(account);
                return {
                    fee = Float.fromInt64(Int64.fromNat64(Nat64.fromNat(FEE))) / 1000000;
                    cumulFee = { cyclesBalance = cumulFee.cyclesBalance; icpBalance = cumulFee.icpBalance; };
                    totalFee = { cyclesBalance = feeBalance.cyclesBalance; icpBalance = feeBalance.icpBalance; };
                    myAllocable = ?({
                        cyclesBalance = feeBalance.cyclesBalance * shareWeighted.shareTimeWeighted / poolShareWeighted.shareTimeWeighted;
                        icpBalance = feeBalance.icpBalance * shareWeighted.shareTimeWeighted / poolShareWeighted.shareTimeWeighted;
                    });
                };
            };
        };
    };
    public query func txnRecord(_txid: Txid) : async (swap: ?TxnRecord){
        return _getTxnRecord(_txid);
    };
    public query func lastTxids(_account: ?Principal) : async [Txid]{
        switch(_account) {
            case(null){
                return _getGlobalLastTxns();
            };
            case(?(account)){
                return _getLastTxns(account);
            };
        }
    };
    public query func getEvents(_account: ?Principal) : async [TxnRecord]{
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
            case(?(account)){
                return Array.chain(_getLastTxns(account), func (value:Txid): [TxnRecord]{
                    switch(_getTxnRecord(value)){
                        case(?(r)){ return [r]; };
                        case(_){ return []; };
                    };
                });
            };
        }
    };
    public query func count(_account: ?Principal) : async Nat{
        switch (_account){
            case(?(account)){ return _getNonce(account); };
            case(_){ return index; };
        };
    };
    public shared(msg) func add(_account: Principal, _data: ?Blob) : async TxnResult{  
        assert(_notPaused());
        let icpBalance = await _getIcpBalance(_getDepositAccount(_account));
        var icpAmount = Nat.sub(icpBalance, Nat64.toNat(ICP_FEE));
        assert(icpAmount >= MIN_ICP_E8S);
        if (icpAmount > ICP_LIMIT){
            icpAmount := ICP_LIMIT;
        };
        let cyclesAvailable = Cycles.available();
        assert(cyclesAvailable >= MIN_CYCLES);
        let res = await _sendIcpFromSA(_account, _getMainAccount(), icpBalance);
        switch(res){
            case(#Err(e)){ throw Error.reject("ICP sending error!");};
            case(_){};
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
        if (icpBalance > icpAmount + Nat64.toNat(ICP_FEE)*2){
            inProgress := List.push((msg.caller, 0, _account, Nat.sub(icpBalance, icpAmount+Nat64.toNat(ICP_FEE))), inProgress);
        };
        let accept = Cycles.accept(cyclesAmount);
        _addLiquidity(cyclesAmount, icpAmount);
        let shareAmount = _calcuShare(cyclesAmount, icpAmount);
        _updatePoolShare(poolShare + shareAmount);
        let shareBalance = _getShare(_account);
        _updateShare(_account, shareBalance + shareAmount);
        // insert record
        let txid = _getTxid(msg.caller);
        var swap: TxnRecord = {
            txid = txid;
            operation = #AddLiquidity;
            account = _account;
            cyclesWallet = ?msg.caller;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #In(cyclesAmount);
            token1Value = #In(icpAmount);
            fee = {token0Fee = 0; token1Fee = 0; };
            share = #Mint(shareAmount);
            time = Time.now();
            data = _data;
        };
        _addNonce(msg.caller);
        _insertTxnRecord(swap);
        let f = _withdraw(); //refund
        return { txid = txid; cycles = #In(cyclesAmount); icpE8s = #In(icpAmount); share = #Mint(shareAmount); };
    };
    public shared(msg) func remove(_share: ?Nat, _cyclesWallet: Principal, _data: ?Blob) : async TxnResult { // null means remove ALL liquidity
        assert(_notPaused());
        var cyclesAmount: Nat = 0;
        var icpAmount: Nat = 0;
        var shareAmount: Nat = 0;
        var shareBalance = _getShare(msg.caller);
        switch(_share) {
            case(null){
                shareAmount := shareBalance;
            };
            case(?(share)){
                shareAmount := share;
            };
        };
        assert(shareAmount <= shareBalance);
        cyclesAmount := _shareToAmount(shareAmount).cycles;
        icpAmount := _shareToAmount(shareAmount).icp;
        assert(cyclesAmount >= MIN_CYCLES and icpAmount >= MIN_ICP_E8S);
        inProgress := List.push((_cyclesWallet, cyclesAmount, msg.caller, icpAmount), inProgress);
        _removeLiquidity(cyclesAmount, icpAmount);
        _updatePoolShare(poolShare - shareAmount);
        _updateShare(msg.caller, shareBalance - shareAmount);
        // insert record
        let txid = _getTxid(msg.caller);
        var swap: TxnRecord = {
            txid = txid;
            operation = #RemoveLiquidity;
            account = msg.caller;
            cyclesWallet = ?_cyclesWallet;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #Out(cyclesAmount);
            token1Value = #Out(_subIcpFee(icpAmount));
            fee = {token0Fee = 0; token1Fee = 0; };
            share = #Burn(shareAmount);
            time = Time.now();
            data = _data;
        };
        _addNonce(msg.caller);
        _insertTxnRecord(swap);
        let f = _withdraw();
        return { txid = txid; cycles = #Out(cyclesAmount); icpE8s = #Out(_subIcpFee(icpAmount)); share = #Burn(shareAmount); };
    };
    public shared(msg) func cyclesToIcp(_account: Principal, _data: ?Blob): async TxnResult {
        assert(_notPaused());
        assert(k != 0);
        var cyclesAvailable = Cycles.available();
        if (cyclesAvailable > CYCLES_LIMIT){
            cyclesAvailable := CYCLES_LIMIT;
        };
        let inCyclesAmount = Cycles.accept(cyclesAvailable);
        assert(inCyclesAmount >= MIN_CYCLES);
        let newPoolCycles = poolCycles + inCyclesAmount;
        let newPoolIcp = k / newPoolCycles;
        var outIcpAmount = Nat.sub(poolIcp, newPoolIcp);
        assert(_volatility(newPoolCycles, newPoolIcp) <= 20);
        _updateLiquidity(newPoolCycles, newPoolIcp);
        _updateVol(_account, inCyclesAmount, outIcpAmount);
        let icpFee = outIcpAmount * FEE / 1000000;
        _chargeFee(0, icpFee);
        outIcpAmount -= icpFee;
        inProgress := List.push((msg.caller, 0, _account, outIcpAmount), inProgress);// send icp
        // insert record
        let txid = _getTxid(msg.caller);
        var swap: TxnRecord = {
            txid = txid;
            operation = #Swap;
            account = _account;
            cyclesWallet = ?msg.caller;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #In(inCyclesAmount);
            token1Value = #Out(_subIcpFee(outIcpAmount));
            fee = {token0Fee = 0; token1Fee = icpFee; };
            share = #NoChange;
            time = Time.now();
            data = _data;
        };
        _addNonce(msg.caller);
        _insertTxnRecord(swap);
        let f = _withdraw();
        return { txid = txid; cycles = #In(inCyclesAmount); icpE8s = #Out(_subIcpFee(outIcpAmount)); share = #NoChange; };
    };
    public shared(msg) func icpToCycles(_icpE8s: Nat, _cyclesWallet: Principal, _data: ?Blob): async TxnResult {
        assert(_notPaused());
        assert(k != 0);
        var inIcpBalance = await _getIcpBalance(_getDepositAccount(msg.caller));
        assert(_icpE8s <= inIcpBalance);
        var inIcpAmount = Nat.sub(_icpE8s, Nat64.toNat(ICP_FEE));
        assert(inIcpAmount >= MIN_ICP_E8S);
        if (inIcpAmount > ICP_LIMIT){
            inIcpAmount := ICP_LIMIT;
        };
        var newPoolIcp = poolIcp + inIcpAmount;
        var newPoolCycles = k / newPoolIcp;
        assert(_volatility(newPoolCycles, newPoolIcp) <= 20);
        let res = await _sendIcpFromSA(msg.caller, _getMainAccount(), inIcpBalance);
        switch(res){
            case(#Err(e)){ throw Error.reject("ICP sending error!");};  //assert()
            case(_){};
        };
        newPoolIcp := poolIcp + inIcpAmount;
        newPoolCycles := k / newPoolIcp;
        var outCyclesAmount = Nat.sub(poolCycles, newPoolCycles);
        _updateLiquidity(newPoolCycles, newPoolIcp);
        _updateVol(msg.caller, outCyclesAmount, inIcpAmount);
        let cyclesFee = outCyclesAmount * FEE / 1000000;
        _chargeFee(cyclesFee, 0);
        outCyclesAmount -= cyclesFee;
        var reFund: Nat = 0;
        if (Nat.sub(inIcpBalance, inIcpAmount) > Nat64.toNat(ICP_FEE)*2){
            reFund := Nat.sub(inIcpBalance, inIcpAmount) - Nat64.toNat(ICP_FEE);
        };
        inProgress := List.push((_cyclesWallet, outCyclesAmount, msg.caller, reFund), inProgress);
        // insert record
        let txid = _getTxid(msg.caller);
        var swap: TxnRecord = {
            txid = txid;
            operation = #Swap;
            account = msg.caller;
            cyclesWallet = ?_cyclesWallet;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #Out(outCyclesAmount);
            token1Value = #In(inIcpAmount);
            fee = {token0Fee = cyclesFee; token1Fee = 0; };
            share = #NoChange;
            time = Time.now();
            data = _data;
        };
        _addNonce(msg.caller);
        _insertTxnRecord(swap);
        let f = _withdraw();
        return { txid = txid; cycles = #Out(outCyclesAmount); icpE8s = #In(inIcpAmount); share = #NoChange; };
    };
    public shared(msg) func claim(_cyclesWallet: Principal, _data: ?Blob) : async TxnResult {
        assert(_notPaused());
        assert(poolShare > 0);
        _updatePoolShare(poolShare);
        let share = _getShare(msg.caller);
        _updateShare(msg.caller, share);
        let shareWeighted = _getShareWeighted(msg.caller);
        let outCyclesAmount = feeBalance.cyclesBalance * shareWeighted.shareTimeWeighted / poolShareWeighted.shareTimeWeighted;
        let outIcpAmount = feeBalance.icpBalance * shareWeighted.shareTimeWeighted / poolShareWeighted.shareTimeWeighted;
        let cumulShareWeighted = _getCumulShareWeighted(msg.caller);
        shares := Trie.put(shares, keyp(msg.caller), Principal.equal, (share, {
            shareTimeWeighted = 0;
            updateTime = _now();
        }, cumulShareWeighted)).0;
        feeBalance.cyclesBalance -= outCyclesAmount;
        feeBalance.icpBalance -= outIcpAmount;
        inProgress := List.push((_cyclesWallet, outCyclesAmount, msg.caller, outIcpAmount), inProgress);
        // insert record
        let txid = _getTxid(msg.caller);
        var swap: TxnRecord = {
            txid = txid;
            operation = #Claim;
            account = msg.caller;
            cyclesWallet = ?_cyclesWallet;
            token0 = #Cycles;
            token1 = #Icp;
            token0Value = #Out(outCyclesAmount);
            token1Value = #Out(_subIcpFee(outIcpAmount));
            fee = {token0Fee = 0; token1Fee = 0; };
            share = #NoChange;
            time = Time.now();
            data = _data;
        };
        _addNonce(msg.caller);
        _insertTxnRecord(swap);
        let f = _withdraw(); // send cycles and icp
        return { txid = txid; cycles = #Out(outCyclesAmount); icpE8s = #Out(_subIcpFee(outIcpAmount)); share = #NoChange; };
    };

    /* 
    * Owner's Management
    */
    public shared(msg) func getErrors() : async [(Nat, ErrorLog)]{  
        assert(_onlyOwner(msg.caller));
        return Trie.toArray<Nat, ErrorLog, (Nat, ErrorLog)>(errors, func (key:Nat, val:ErrorLog):(Nat, ErrorLog){
            return (key, val);
        });
    };
    public shared(msg) func handleError(_index: Nat, toDelete: Bool, _replaceCyclesWallet: ?Principal) : async Bool{
        if (toDelete){
            errors := Trie.remove(errors, keyn(_index), Nat.equal).0;
        }else{
            switch(Trie.get(errors, keyn(_index), Nat.equal)){
                case(?(error)){
                    var cyclesWallet = error.withdraw.0;
                    switch(_replaceCyclesWallet){
                        case(?(wallet)){ cyclesWallet := wallet; };
                        case(_){};
                    };
                    inProgress := List.push((cyclesWallet, error.withdraw.1, error.withdraw.2, error.withdraw.3), inProgress);
                    let f = _withdraw();
                    errors := Trie.remove(errors, keyn(_index), Nat.equal).0;
                };
                case(_){ return false; };
            };
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
        CYCLES_LIMIT := Option.get(config.MIN_CYCLES, MIN_CYCLES);
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
    /// query canister status: Add itself as a controller, canister_id = Principal.fromActor(<your actor name>)
    public func canister_status() : async Monitee.canister_status {
        let ic : Monitee.IC = actor("aaaaa-aa");
        await ic.canister_status({ canister_id = Principal.fromActor(this) });
    };
    /// canister memory
    public query func getMemory() : async (Nat,Nat,Nat,Nat32){
        return (Prim.rts_memory_size(), Prim.rts_heap_size(), Prim.rts_total_allocation(),Prim.stableMemorySize());
    };
    /// canister cycles
    public query func getCycles() : async Nat{
        return return Cycles.balance();
    };
}