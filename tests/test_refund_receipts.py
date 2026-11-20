"""Actual economy and receipt state machine, isolated from native storage and real money."""
from pathlib import Path
import unittest
from lupa import lua54

ROOT = Path(__file__).resolve().parents[1]

class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.lua = lua54.LuaRuntime()
        self.lua.execute('''
KVP={};ENC={};seq=0;CURRENT='A';MONEY=100;credits=0;debits=0;CREDIT=true;BADWRITE=false;GENERATION=10;OWNER='license:original';LEASE=false
WCUtil={isFinite=function(n) return n==n and math.abs(n)<math.huge end,round2=function(n) return math.floor(n*100+0.5)/100 end}
WCDebug={warn=function() end,log=function() end};CreatorLogs={Emit=function() end}
WCSessions={activeCharacter=function() return CURRENT and {charid=CURRENT} end}
function GetResourceKvpString(k) return KVP[k] end
function SetResourceKvp(k,v) if BADWRITE then error('storage unavailable') end KVP[k]=v end
function GetGameTimer() return 1000 end
function AddEventHandler() end
function CreateThread() end
function RegisterCommand() end
json={encode=function(row) seq=seq+1;local c={};for k,v in pairs(row) do c[k]=v end;ENC[tostring(seq)]=c;return tostring(seq) end,
decode=function(raw) if not ENC[raw] then error('bad json') end return ENC[raw] end}
U={getMoney=function() return MONEY end,canBuy=function(_,value) debits=debits+1;MONEY=MONEY-value;if DEBIT_ERROR then error('interrupted debit') end;return true end,
addMoney=function(_,value) if CREDIT=='error' then MONEY=MONEY+value;credits=credits+1;error('uncertain credit') end;if CREDIT==true then MONEY=MONEY+value;credits=credits+1 end;return CREDIT end}
w={framework={getUser=function() return U end}}
Bridge={GetLicense=function() return OWNER end}
function GetResourceState() return 'started' end
U.data={PlayerData={id=10}}
exports={
    w_core={WithCitizenGeneration=function(_,cid,expected,fn)
        if DENY_GENERATION then return false,DENY_GENERATION end
        if cid~=CURRENT or expected~=GENERATION then return false,'generation_changed' end
        LEASE=true;local result=fn();LEASE=false;return result
    end},
    w_lib={
        FwName=function() return 'w_core' end,
        FwBackend=function() return 'wcore' end,
        FwGetCharacterGeneration=function(_,src)
            local id = U and U.data and U.data.PlayerData and U.data.PlayerData.id
            return CURRENT, id
        end,
        FwWithCitizenGeneration=function(_,cid,expected,fn)
            return exports.w_core:WithCitizenGeneration(cid,expected,fn)
        end,
    },
}
function receipt() return json.decode(KVP['w_creators:refund:A:core:10']) end
''')
        for rel in ['shared/result.lua', 'server/core/refunds.lua', 'server/core/economy.lua']:
            self.lua.execute((ROOT / rel).read_text(encoding='utf-8-sig'))
    def run_lua(self, code): self.lua.execute(code)
    def test_success_receipt_and_failed_persist_refunded(self):
        self.run_lua("local r=WCEconomy.withCharge(1,25,'test',function() return true end);assert(r.ok and MONEY==75 and receipt().state=='delivered');r=WCEconomy.withCharge(1,10,'test',function() return false end);assert(not r.ok and r.charged==0 and r.data.refunded and MONEY==75 and receipt().state=='refunded')")
    def test_failed_refund_is_durable_and_never_retries_uncertain_credit(self):
        self.run_lua("CREDIT=false;local r=WCEconomy.withCharge(1,25,'test',function() return false end);assert(r.code=='REFUND_REVIEW' and r.charged==25 and r.data.refundId and MONEY==75 and receipt().state=='review');local q=WCEconomy.withCharge(1,5,'test',function() return true end);assert(not q.ok and debits==1);CREDIT=true;WCRefunds.retry(1);WCRefunds.retry(1);assert(MONEY==75 and credits==0 and receipt().state=='review')")
    def test_crash_during_credit_is_quarantined_after_restart(self):
        self.run_lua("CREDIT='error';local r=WCEconomy.withCharge(1,25,'test',function() return false end);assert(r.code=='REFUND_REVIEW' and r.charged==25 and receipt().state=='review' and credits==1)")
        self.lua.execute((ROOT / 'server/core/refunds.lua').read_text(encoding='utf-8-sig'))
        self.run_lua("CREDIT=true;WCRefunds.retry(1);assert(credits==1);local r=WCEconomy.withCharge(1,5,'test',function() return true end);assert(r.code=='REFUND_REVIEW' and debits==1)")
    def test_reused_source_cannot_credit_another_character(self):
        self.run_lua("local r=WCEconomy.withCharge(1,25,'test',function() CURRENT='B';return false end);assert(r.code=='REFUND_PENDING' and credits==0);WCRefunds.retry(1);assert(credits==0);CURRENT='A';WCRefunds.retry(1);assert(credits==1 and MONEY==100)")
    def test_journal_failure_stops_debit(self):
        self.run_lua("BADWRITE=true;local r=WCEconomy.withCharge(1,25,'test',function() error('must not run') end);assert(not r.ok and debits==0 and MONEY==100)")
    def test_uncertain_debit_requires_review(self):
        self.run_lua("DEBIT_ERROR=true;local r=WCEconomy.withCharge(1,25,'test',function() error('must not run') end);assert(r.code=='REFUND_REVIEW' and r.data.refundId and receipt().state=='review');CREDIT=true;WCRefunds.retry(1);assert(credits==0)")
    def test_corrupt_receipt_blocks_and_free_operation_does_not_write(self):
        self.run_lua("KVP['w_creators:refund:A:core:10']='corrupt';local r=WCEconomy.withCharge(1,25,'test',function() return true end);assert(r.code=='REFUND_REVIEW' and debits==0);CURRENT=nil;r=WCEconomy.withCharge(1,0,'free',function() return true end);assert(r.ok and debits==0)")
    def test_same_number_new_generation_never_inherits_refund(self):
        self.run_lua("CREDIT=false;WCEconomy.withCharge(1,25,'test',function() return false end);CREDIT=true;GENERATION=11;U.data.PlayerData.id=11;WCRefunds.retry(1);assert(credits==0 and receipt().state=='review');local r=WCEconomy.withCharge(1,5,'new-holder',function() return true end);assert(r.ok and credits==0 and receipt().state=='review')")
    def test_owner_change_without_new_row_id_still_cannot_receive_refund(self):
        self.run_lua("CREDIT=false;WCEconomy.withCharge(1,25,'test',function() return false end);CREDIT=true;OWNER='license:new-holder';WCRefunds.retry(1);assert(credits==0);local r=WCEconomy.withCharge(1,5,'test',function() return true end);assert(r.code=='REFUND_REVIEW' and debits==1)")
    def test_generation_lock_is_held_for_charge_persistence_and_refund(self):
        self.run_lua("local oldDebit=U.canBuy;U.canBuy=function(...) assert(LEASE);return oldDebit(...) end;local oldCredit=U.addMoney;U.addMoney=function(...) assert(LEASE);return oldCredit(...) end;local r=WCEconomy.withCharge(1,25,'test',function() assert(LEASE);return false end);assert(not r.ok and r.data.refunded and credits==1)")
    def test_generation_refusal_stops_money_before_callback(self):
        self.run_lua("DENY_GENERATION='generation_busy';local r=WCEconomy.withCharge(1,25,'test',function() error('must not run') end);assert(not r.ok and debits==0 and credits==0)")
    def install_real_generation_export(self):
        self.run_lua("GEN_EXPORTS={};exports=function(k,fn) GEN_EXPORTS[k]=fn end;WCore={Citizen={Normalize=function(cid)return cid end,IsBusy=function()return false end,RowPurged=function()return false end,RowMoved=function()return false end}};function GetInvokingResource() return 'w_creators' end;DB_ROW=10;MySQL={single={await=function()return {id=DB_ROW}end}}")
        self.lua.execute((ROOT.parent / 'w_core/server/generation.lua').read_text(encoding='utf-8-sig'))
        self.run_lua("exports={w_core={WithCitizenGeneration=function(_,...)return GEN_EXPORTS.WithCitizenGeneration(...)end},w_lib={FwName=function() return 'w_core' end,FwBackend=function() return 'wcore' end,FwGetCharacterGeneration=function() return CURRENT, U and U.data and U.data.PlayerData and U.data.PlayerData.id end,FwWithCitizenGeneration=function(_,...)return GEN_EXPORTS.WithCitizenGeneration(...)end}}")
    def test_actual_core_export_holds_generation_through_compensation(self):
        self.install_real_generation_export()
        self.run_lua("local oldDebit=U.canBuy;U.canBuy=function(...) assert(WCore.Citizen.HasGenerationLease('A'));return oldDebit(...) end;local oldCredit=U.addMoney;U.addMoney=function(...) assert(WCore.Citizen.HasGenerationLease('A'));return oldCredit(...) end;local r=WCEconomy.withCharge(1,25,'test',function() assert(WCore.Citizen.HasGenerationLease('A'));return false end);assert(not r.ok and r.data.refunded and credits==1 and not WCore.Citizen.HasGenerationLease('A'))")
    def test_character_switch_during_actual_generation_lookup_never_debits_new_character(self):
        self.install_real_generation_export()
        self.run_lua("MySQL.single.await=function() coroutine.yield('generation_lookup');return {id=10} end;local result;local co=coroutine.create(function() result=WCEconomy.withCharge(1,25,'test',function() PERSISTED=true;return true end) end);local ok,where=coroutine.resume(co);assert(ok and where=='generation_lookup' and WCore.Citizen.HasGenerationLease('A'));CURRENT='B';U.data.PlayerData.id=11;assert(coroutine.resume(co));assert(not result.ok and debits==0 and credits==0 and MONEY==100 and not PERSISTED and receipt().state=='cancelled' and not WCore.Citizen.HasGenerationLease('A'))")
    def test_actual_core_rejects_reassigned_database_row_with_stale_loaded_id(self):
        self.install_real_generation_export()
        self.run_lua("WCEconomy.withCharge(1,25,'test',function() CURRENT='B';return false end);CURRENT='A';DB_ROW=11;WCRefunds.retry(1);assert(credits==0 and receipt().state=='review' and not WCore.Citizen.HasGenerationLease('A'))")
    def install_real_core_money(self):
        self.run_lua("WCore={Functions={}};COREPLAYER={PlayerData={citizenid='A',id=10},Offline=true,Functions={}};exports.w_centralbank={IsReady=function()return true end,HydratePlayer=function()return {}end,AdjustPlayer=function(_,cid,kind,delta) MONEY=MONEY+delta;if delta>0 then credits=credits+1 else debits=debits+1 end;return nil,'commit_unknown' end}")
        self.lua.execute((ROOT.parent / 'w_core/server/economy.lua').read_text(encoding='utf-8-sig'))
    def test_actual_core_unknown_credit_is_never_replayed(self):
        self.install_real_core_money()
        self.run_lua("U.addMoney=function(_,amount)return WCore.Economy.change(COREPLAYER,'cash',amount,'add','w_lib') and true or false end;local result=WCEconomy.withCharge(1,25,'test',function()return false end);assert(result.code=='REFUND_REVIEW' and MONEY==100 and receipt().state=='review' and credits==1);WCRefunds.retry(1);assert(MONEY==100 and credits==1 and receipt().state=='review')")
    def test_actual_core_unknown_debit_blocks_a_new_charge(self):
        self.install_real_core_money()
        self.run_lua("U.canBuy=function(_,amount)return WCore.Economy.change(COREPLAYER,'cash',amount,'remove','w_lib') and true or false end;local result=WCEconomy.withCharge(1,25,'test',function()PERSISTED=true;return true end);assert(result.code=='REFUND_REVIEW' and MONEY==75 and debits==1 and not PERSISTED and receipt().state=='review');result=WCEconomy.withCharge(1,25,'test',function()PERSISTED=true;return true end);assert(result.code=='REFUND_REVIEW' and MONEY==75 and debits==1 and not PERSISTED)")
    def test_interrupted_credit_state_never_retries(self):
        self.run_lua("CREDIT=false;WCEconomy.withCharge(1,25,'test',function() return false end);WCRefunds.update(receipt(),'refunding');CREDIT=true;WCRefunds.retry(1);assert(credits==0 and receipt().state=='refunding')")

if __name__ == '__main__': unittest.main()
