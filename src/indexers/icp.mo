import Vector "mo:vector";
import Ledger "../services/icp_ledger";
import Principal "mo:base/Principal";
import Error "mo:base/Error";
import Timer "mo:base/Timer";
import Map "mo:map/Map";
import T "../types";
import Nat64 "mo:base/Nat64";
import Array "mo:base/Array";
import History "../history";
import Blob "mo:base/Blob";
import Monitor "../monitor";
import Prim "mo:⛔";
import ErrLog "../errlog";

module {

    public type Mem = {
        var last_indexed_tx : Nat;
        source2vector : Map.Map<Blob, T.DVectorId>;
        destination2vector : Map.Map<Blob, T.DVectorId>;
        var paused: Bool;
    };

    public class Indexer({
        errlog : ErrLog.ErrLog;
        mem : Mem;
        ledger_id : Principal;
        dvectors : Map.Map<T.DVectorId, T.DVector>;
        history : History.History;
        monitor : Monitor.Monitor;
        metric_key: Monitor.MetricKey;
    }) {

        let ledger = actor (Principal.toText(ledger_id)) : Ledger.Self;

        public func register_vector(id : T.DVectorId, dv : T.DVector) {
            if (dv.source.ledger == ledger_id) {
                ignore Map.put<Blob, T.DVectorId>(mem.source2vector, Map.bhash, Principal.toLedgerAccount(dv.source.address.owner, dv.source.address.subaccount), id);
            };

            if (dv.destination.ledger == ledger_id) {
                ignore Map.put<Blob, T.DVectorId>(mem.destination2vector, Map.bhash, Principal.toLedgerAccount(dv.destination.address.owner, dv.destination.address.subaccount), id);
            };
        };

        private func get_source_vector(account : Blob) : ?T.DVectorId {
            return Map.get<Blob, T.DVectorId>(mem.source2vector, Map.bhash, account);
        };

        private func get_destination_vector(account : Blob) : ?T.DVectorId {
            return Map.get<Blob, T.DVectorId>(mem.destination2vector, Map.bhash, account);
        };

        private func processtx(transactions : [Ledger.CandidBlock]) {
            
            label looptx for (t in transactions.vals()) {

                switch(t.transaction.operation) {
                    case (?#Mint(mint)) {
                        ignore do ? {
                            let vid = get_source_vector(mint.to)!;
                            let v = Map.get<T.DVectorId, T.DVector>(dvectors, Map.n32hash, vid)!;

                            v.source_balance += Nat64.toNat(mint.amount.e8s);

                            history.add([v], #source_in({
                                vid = vid;
                                amount = Nat64.toNat(mint.amount.e8s);
                                fee = 0;
                            }))
                        };
                    };
                    case (?#Transfer(tr)) {
                        let amount = Nat64.toNat(tr.amount.e8s);

                        ignore do ? {
                            let vid = get_source_vector(tr.to)!;
                            let v = Map.get<T.DVectorId, T.DVector>(dvectors, Map.n32hash, vid)!;
                            let fee = Nat64.toNat(tr.fee.e8s);

                            v.source_balance += amount;

                            history.add([v], #source_in({
                                vid = vid;
                                amount = amount;
                                fee = fee;
                            }))
                        };

                        ignore do ? {
                            let vid = get_source_vector(tr.from)!;
                            let v = Map.get<T.DVectorId, T.DVector>(dvectors, Map.n32hash, vid)!;
                            let fee = Nat64.toNat(tr.fee.e8s);

                            v.source_balance -= amount + v.source.ledger_fee;

                            // look for a pending transaction and remove it
                            v.unconfirmed_transactions := Array.filter<T.UnconfirmedTransaction>(
                                v.unconfirmed_transactions,
                                func(ut) : Bool {
                                    t.transaction.icrc1_memo != ?ut.memo;
                                },
                            );

                            history.add([v], #source_out({
                                vid = vid;
                                amount = amount;
                                fee = fee;
                            }))

                        };

                        ignore do ? {
                            let vid = get_destination_vector(tr.to)!;
                            let v = Map.get<T.DVectorId, T.DVector>(dvectors, Map.n32hash, vid)!;
                         
                            let fee = Nat64.toNat(tr.fee.e8s);

                            if (v.remote_destination == false) {
                                v.destination_balance += amount;
                          
                                let vtx_id:?Nat64 = do ? { T.DNat64(Blob.toArray(t.transaction.icrc1_memo!))! };

                                history.add([v], #destination_in({
                                    vtx_id;
                                    vid = vid;
                                    amount = amount;
                                    fee = fee;
                                }))
                            }
                           
                        };

                        ignore do ? {
                            let vid = get_destination_vector(tr.from)!;
                            let v = Map.get<T.DVectorId, T.DVector>(dvectors, Map.n32hash, vid)!;
                            
                            let fee = Nat64.toNat(tr.fee.e8s);

                            // We are only tracking the destination balance of local accounts
                            if (v.remote_destination == false) {
                                v.destination_balance -= amount + v.destination.ledger_fee;
                                
                                // This is here for widhtrawl transactions
                                v.unconfirmed_transactions := Array.filter<T.UnconfirmedTransaction>(
                                    v.unconfirmed_transactions,
                                    func(ut) : Bool {
                                        t.transaction.icrc1_memo != ?ut.memo;
                                    },
                                );

                                history.add([v], #destination_out({
                                    vid = vid;
                                    amount = amount;
                                    fee = fee;
                                }))
                            }
                        
                        };
                    };
                    case (_) ();
                };

            };

            
        };

        type TransactionUnordered = {
            start : Nat64;
            transactions : [Ledger.CandidBlock];
        };

        private func proc() : async () {
            if (mem.paused) return;
             let inst_start = Prim.performanceCounter(1); // 1 is preserving with async

            // start from the end of last_indexed_tx = 0
            if (mem.last_indexed_tx == 0) {
                let rez = await ledger.query_blocks({
                    start = 0;
                    length = 1;
                });
                mem.last_indexed_tx := Nat64.toNat(rez.chain_length) - 1;
            };

            let rez = await ledger.query_blocks({
                start = Nat64.fromNat(mem.last_indexed_tx);
                length = 1000;
            });

            if (rez.archived_blocks.size() == 0) {
                // We can just process the transactions
                processtx(rez.blocks);
                mem.last_indexed_tx += rez.blocks.size();
            } else {
                // We need to collect transactions from archive and get them in order
                let unordered = Vector.new<TransactionUnordered>();

                for (atx in rez.archived_blocks.vals()) {
                    let #Ok(txresp) = await atx.callback({
                        start = atx.start;
                        length = atx.length;
                    }) else return;

                    Vector.add(
                        unordered,
                        {
                            start = atx.start;
                            transactions = txresp.blocks;
                        },
                    );
                };

                let sorted = Array.sort<TransactionUnordered>(
                    Vector.toArray(unordered),
                    func(a, b) {
                        Nat64.compare(a.start, b.start);
                    },
                );

                for (u in sorted.vals()) {
                    assert (u.start == Nat64.fromNat(mem.last_indexed_tx));
                    processtx(u.transactions);
                    mem.last_indexed_tx += u.transactions.size();
                };

                if (rez.blocks.size() != 0) {
                    processtx(rez.blocks);
                    mem.last_indexed_tx += rez.blocks.size();
                };
            };

            let inst_end = Prim.performanceCounter(1); // 1 is preserving with async
            monitor.add(metric_key, inst_end - inst_start);
        };

        private func qtimer<system>() : async () {
            try {
                await proc();
            } catch (e) {
                errlog.add("indexers:icp:" # Principal.toText(ledger_id) # ":" # Error.message(e));
            };

            ignore Timer.setTimer<system>(#seconds 2, qtimer);

        };

        public func start_timer<system>() {
            ignore Timer.setTimer<system>(#seconds 2, qtimer);
        };
    };

};
