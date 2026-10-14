//+------------------------------------------------------------------+
//| ReverseTrail_SAR_EntryProtect_30Pip_v1_20.mq5                                   |
//| Independent MT5 Expert Advisor - NOT a Katarina AI component     |
//| Strategy: one hedging position + trailing opposite STOP order    |
//| IMPORTANT: DEMO/STRATEGY TESTER FIRST. No profitability guarantee|
//+------------------------------------------------------------------+
#property copyright "Standalone educational EA"
#property version   "1.20"
#property strict
#property description "Candle pending 30 pips. Reverse opposite STOP at entry if broker permits; otherwise 30-pip trail."
#property description "Attach ONLY ONE instance per symbol+magic. Demo/backtest first."

#include <Trade/Trade.mqh>

// 1) Initial entry method (editable in the EA Inputs tab)
enum ENUM_ENTRY_MODE
  {
   ENTRY_EMA_TREND=0, // Buy if EMA50>EMA200 and close above both; inverse for Sell
   ENTRY_START_BUY=1, // Buy immediately when starting a new cycle
   ENTRY_START_SELL=2,// Sell immediately when starting a new cycle
   ENTRY_MANAGE_ONLY=3,// Do not open initial entry; manage existing EA-magic positions
   ENTRY_CANDLE_STOP=4 // Bearish closed candle->BuyStop, bullish->SellStop
  };

// 2) Distance calculation (price units, not broker 'pips')
enum ENUM_DISTANCE_MODE
  {
   DISTANCE_ATR=0,     // ATR * multiplier, clamped to min/max distance
   DISTANCE_FIXED=1    // Fixed distance measured in XAUUSD PRICE units
  };

input group "00 | GENERAL / ISOLATION"
input long                  InpMagic                  = 2610141820;
input double                InpLot                    = 0.01;
input double                InpMaxSpreadPrice         = 1.00;     // XAU PRICE units; initial entry only, 0=no filter
input int                   InpDeviationPoints       = 30;
input bool                  InpRestartAfterFlat       = false;    // False: stop after SL/TP/manual close
input bool                  InpResetCycleStateOnInit  = false;    // Set true ONCE to start a fresh cycle

input group "01 | FIRST ENTRY"
input ENUM_ENTRY_MODE       InpInitialEntry           = ENTRY_CANDLE_STOP;
input ENUM_TIMEFRAMES       InpSignalTF               = PERIOD_M1;
input int                   InpFastEMA                = 50;
input int                   InpSlowEMA                = 200;
input double                InpCandleEntryBufferPrice = 0.00; // Extra PRICE buffer beyond 30 pips; 0 = exactly 30 pips
input double                InpCandleRepriceStepPrice = 0.10; // Only improve pending by at least this price step
input bool                  InpCandleFlipPending      = true; // Flip first STOP when latest closed candle changes color

input group "02 | REVERSE TRAILING DISTANCE"
input ENUM_DISTANCE_MODE    InpDistanceMode           = DISTANCE_FIXED;
input double                InpFixedDistancePrice     = 3.00; // LEGACY; retained for compatibility
input double                InpTrailingPips           = 30.0; // STOP distance from live ask/bid in PIPS
input double                InpPipSizePrice           = 0.10; // XAUUSD: 1 pip = 0.10 PRICE by default (30 pips = 3.00)
input bool                  InpReverseStartAtEntry    = true; // Prioritize opposite STOP at open-position entry once legal
input ENUM_TIMEFRAMES       InpATRTF                  = PERIOD_M1;
input int                   InpATRPeriod              = 14;
input double                InpATRMultiplier          = 2.00;
input double                InpMinDistancePrice       = 2.50;
input double                InpMaxDistancePrice       = 8.00;

input group "03 | PENDING ORDER TRAILING STEP"
input double                InpTrailingStepPrice      = 0.10;     // Minimum price improvement for modify
input int                   InpMinSecondsPerModify    = 1;
input int                   InpMinSecondsPerEntryTry  = 10;

input group "04 | OPTIONAL EXITS / DAILY LIMITS"
input double                InpHardSLDistancePrice    = 15.00;    // 0 disables broker SL
input double                InpTakeProfitDistancePrice= 0.00;     // 0 disables TP; TP may end cycle
input double                InpDailyProfitMoney       = 0.00;     // 0 disables daily profit pause
input double                InpDailyLossMoney         = 25.00;     // 0 disables daily loss pause

CTrade   g_trade;
int      g_atrHandle=INVALID_HANDLE;
int      g_emaFastHandle=INVALID_HANDLE;
int      g_emaSlowHandle=INVALID_HANDLE;
bool     g_cycleStarted=false;
bool     g_haltedToday=false;
int      g_haltedDay=0;
bool     g_processing=false;
datetime g_lastModifyAt=0;
datetime g_lastEntryTryAt=0;
string   g_startedKey="";
string   g_dailyHaltKey="";
string   g_status="Starting";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double TickSize()
  {
   double size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(size<=0.0) size=_Point;
   return size;
  }

double PriceUp(const double value)
  {
   double ts=TickSize();
   return NormalizeDouble(MathCeil((value/ts)-1e-9)*ts,_Digits);
  }

double PriceDown(const double value)
  {
   double ts=TickSize();
   return NormalizeDouble(MathFloor((value/ts)+1e-9)*ts,_Digits);
  }

double BrokerMinDistance()
  {
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax((double)stops,(double)freeze)*_Point+2.0*TickSize();
  }

bool TradeOK(const bool methodReturned)
  {
   uint rc=g_trade.ResultRetcode();
   return methodReturned &&
          (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED ||
           rc==TRADE_RETCODE_DONE_PARTIAL || rc==TRADE_RETCODE_NO_CHANGES);
  }

void TradeError(const string operation)
  {
   PrintFormat("[ReverseTrail] %s failed, retcode=%u (%s), lastError=%d",
               operation,g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription(),GetLastError());
  }

int TodayStart()
  {
   MqlDateTime day;
   TimeToStruct(TimeCurrent(),day);
   day.hour=0; day.min=0; day.sec=0;
   return (int)StructToTime(day);
  }

bool IsManagedPosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   return (PositionGetString(POSITION_SYMBOL)==_Symbol &&
           PositionGetInteger(POSITION_MAGIC)==InpMagic);
  }

bool IsManagedOrder(const ulong ticket)
  {
   if(!OrderSelect(ticket)) return false;
   return (OrderGetString(ORDER_SYMBOL)==_Symbol &&
           OrderGetInteger(ORDER_MAGIC)==InpMagic);
  }

void MarkCycleStarted()
  {
   if(!g_cycleStarted)
     {
      g_cycleStarted=true;
      if(!MQLInfoInteger(MQL_TESTER)) GlobalVariableSet(g_startedKey,1.0);
     }
  }

// Broker SL/TP are attached to BOTH market and pending orders.
void BuildStops(const bool isBuy,const double entry,double &sl,double &tp)
  {
   double minD=BrokerMinDistance();
   sl=0.0; tp=0.0;
   if(InpHardSLDistancePrice>0)
     {
      double d=MathMax(InpHardSLDistancePrice,minD);
      sl=(isBuy ? PriceDown(entry-d) : PriceUp(entry+d));
     }
   if(InpTakeProfitDistancePrice>0)
     {
      double d=MathMax(InpTakeProfitDistancePrice,minD);
      tp=(isBuy ? PriceUp(entry+d) : PriceDown(entry-d));
     }
  }

double ReverseDistance()
  {
   // Default: 30 pips * 0.10 XAU price/pip = $3.00.
   // Broker STOP/FREEZE levels have priority when bigger than 30 pips.
   return MathMax(InpTrailingPips*InpPipSizePrice,BrokerMinDistance());
  }

//+------------------------------------------------------------------+
//| Read all positions owned by this EA. Keep the most recently open.|
//+------------------------------------------------------------------+
ulong NewestPosition(ENUM_POSITION_TYPE &side,int &count)
  {
   count=0;
   ulong latest=0;
   long latestMsc=-1;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(ticket)) continue;
      count++;
      long when=PositionGetInteger(POSITION_TIME_MSC);
      if(when>latestMsc || (when==latestMsc && ticket>latest))
        {
         latestMsc=when;
         latest=ticket;
         side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        }
     }
   return latest;
  }

bool CloseAllExcept(const ulong keep)
  {
   bool all=true;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || ticket==keep || !IsManagedPosition(ticket)) continue;
      ResetLastError();
      bool ok=g_trade.PositionClose(ticket,(ulong)InpDeviationPoints);
      if(!TradeOK(ok))
        {
         TradeError("Close older position #"+IntegerToString((long)ticket));
         all=false;
        }
      else
         PrintFormat("[ReverseTrail] Closed older position #%I64u after reverse.",ticket);
     }
   return all;
  }

void CancelAllPending()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(ticket)) continue;
      ResetLastError();
      bool ok=g_trade.OrderDelete(ticket);
      if(!TradeOK(ok)) TradeError("Delete pending #"+IntegerToString((long)ticket));
     }
  }

void CloseAllPositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(ticket)) continue;
      ResetLastError();
      bool ok=g_trade.PositionClose(ticket,(ulong)InpDeviationPoints);
      if(!TradeOK(ok)) TradeError("Safety close #"+IntegerToString((long)ticket));
     }
  }

// Includes realized P/L + fees for this EA today; adds live floating P/L.
double DailyManagedPnL()
  {
   double profit=0.0;
   if(HistorySelect((datetime)TodayStart(),TimeCurrent()))
     {
      for(int i=HistoryDealsTotal()-1;i>=0;i--)
        {
         ulong ticket=HistoryDealGetTicket(i);
         if(ticket==0) continue;
         if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
         if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagic) continue;
         profit+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
         profit+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         profit+=HistoryDealGetDouble(ticket,DEAL_SWAP);
         profit+=HistoryDealGetDouble(ticket,DEAL_FEE);
        }
     }
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(ticket)) continue;
      profit+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return profit;
  }

void CheckDailyHalt()
  {
   if(g_haltedToday) return;
   if(InpDailyProfitMoney<=0.0 && InpDailyLossMoney<=0.0) return;
   double today=DailyManagedPnL();
   if((InpDailyProfitMoney>0.0 && today>=InpDailyProfitMoney) ||
      (InpDailyLossMoney>0.0 && today<=-InpDailyLossMoney))
     {
      g_haltedToday=true;
      g_haltedDay=TodayStart();
      if(!MQLInfoInteger(MQL_TESTER)) GlobalVariableSet(g_dailyHaltKey,(double)TodayStart());
      g_status="Daily profit/loss threshold reached; closing and pausing";
      PrintFormat("[ReverseTrail] Daily stop hit: %.2f %s",today,AccountInfoString(ACCOUNT_CURRENCY));
     }
  }

//+------------------------------------------------------------------+
//| First order: trend filter or user-selected direction.            |
//+------------------------------------------------------------------+
int GetInitialDirection() // 1 = BUY, -1 = SELL, 0 = wait
  {
   if(InpInitialEntry==ENTRY_START_BUY)  return  1;
   if(InpInitialEntry==ENTRY_START_SELL) return -1;
   if(InpInitialEntry==ENTRY_MANAGE_ONLY)return 0;

   double fast[1],slow[1];
   if(g_emaFastHandle==INVALID_HANDLE || g_emaSlowHandle==INVALID_HANDLE)
      return 0;
   if(Bars(_Symbol,InpSignalTF)<InpSlowEMA+5) return 0;
   if(CopyBuffer(g_emaFastHandle,0,1,1,fast)!=1 ||
      CopyBuffer(g_emaSlowHandle,0,1,1,slow)!=1) return 0;
   double close1=iClose(_Symbol,InpSignalTF,1);
   if(close1>fast[0] && fast[0]>slow[0]) return 1;
   if(close1<fast[0] && fast[0]<slow[0]) return -1;
   return 0;
  }

// First entry is a PENDING STOP (not a market order).
// Last CLOSED bearish candle: BUY STOP at current ASK + 30 pips.
// As the market falls, BUY STOP only trails DOWN.
// Last CLOSED bullish candle: SELL STOP at current BID - 30 pips.
// As the market rises, SELL STOP only trails UP.
// If color flips, optionally switch first pending order side. Doji keeps it.
// After fill, ProcessCycle places the reverse STOP IMMEDIATELY on the next
// trade event/tick/timer, using the tick-based reverse trailing already below.
void EnsureFirstCandlePending(const MqlTick &tick)
  {
   if(Bars(_Symbol,InpSignalTF)<3)
     {
      g_status="Waiting for closed candle history";
      return;
     }
   double barOpen=iOpen(_Symbol,InpSignalTF,1);
   double barClose=iClose(_Symbol,InpSignalTF,1);
   double barHigh=iHigh(_Symbol,InpSignalTF,1);
   double barLow=iLow(_Symbol,InpSignalTF,1);
   if(barOpen<=0.0 || barClose<=0.0 || barHigh<=0.0 || barLow<=0.0)
     {
      g_status="Candle OHLC unavailable";
      return;
     }

   ENUM_ORDER_TYPE needed=(ENUM_ORDER_TYPE)-1;
   if(barClose<barOpen) needed=ORDER_TYPE_BUY_STOP;
   if(barClose>barOpen) needed=ORDER_TYPE_SELL_STOP;
   ulong keep=0;
   bool deleteOK=true;
   // On doji, preserve a valid current first pending; do not place a new one.
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(ticket)) continue;
      ENUM_ORDER_TYPE existing=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool usable=(((int)needed==-1 && (existing==ORDER_TYPE_BUY_STOP || existing==ORDER_TYPE_SELL_STOP)) ||
                   (existing==needed) ||
                   (!InpCandleFlipPending && (existing==ORDER_TYPE_BUY_STOP || existing==ORDER_TYPE_SELL_STOP)));
      if(keep==0 && usable)
        {
         keep=ticket;
         continue;
        }
      bool ok=g_trade.OrderDelete(ticket);
      if(!TradeOK(ok))
        {
         TradeError("Remove stale/duplicate first pending");
         deleteOK=false;
        }
     }
   if(!deleteOK)
     {
      g_status="Cannot remove old pending: check Experts";
      return;
     }
   if((int)needed==-1)
     {
      g_status=(keep!=0 ? "Doji: keeping first pending" : "Doji: waiting for bearish/bullish candle");
      return;
     }
   // When flip is off, honor the already-present first pending side.
   if(keep!=0 && OrderSelect(keep))
     {
      ENUM_ORDER_TYPE k=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(k!=needed)
        {
         g_status="First pending kept: candle flip disabled";
         return;
        }
     }
   if(InpMaxSpreadPrice>0.0 && tick.ask-tick.bid>InpMaxSpreadPrice)
     {
      g_status="Spread too wide for candle entry";
      return;
     }

   double minD=BrokerMinDistance();
   double firstDist=MathMax(ReverseDistance()+InpCandleEntryBufferPrice,minD);
   double desired=(needed==ORDER_TYPE_BUY_STOP ?
                   PriceUp(tick.ask+firstDist) :
                   PriceDown(tick.bid-firstDist));
   double sl,tp;
   BuildStops(needed==ORDER_TYPE_BUY_STOP,desired,sl,tp);
   if(keep==0)
     {
      if((int)(TimeCurrent()-g_lastEntryTryAt)<InpMinSecondsPerEntryTry) return;
      g_lastEntryTryAt=TimeCurrent();
      ResetLastError();
      bool ok=(needed==ORDER_TYPE_BUY_STOP ?
               g_trade.BuyStop(InpLot,desired,_Symbol,sl,tp,ORDER_TIME_GTC,0,"RTSAR candle BUY STOP") :
               g_trade.SellStop(InpLot,desired,_Symbol,sl,tp,ORDER_TIME_GTC,0,"RTSAR candle SELL STOP"));
      if(TradeOK(ok))
        {
         g_status="First candle pending placed";
         PrintFormat("[ReverseTrail] Candle %s -> first %s @ %.*f",barClose<barOpen ? "DOWN":"UP",EnumToString(needed),_Digits,desired);
        }
      else
        {
         TradeError("Place first candle pending");
         g_status="Initial STOP rejected; inspect Experts/Journal";
        }
      return;
     }
   if(!OrderSelect(keep)) return;
   double old=OrderGetDouble(ORDER_PRICE_OPEN);
   double step=MathMax(TickSize(),InpCandleRepriceStepPrice);
   bool improve=(needed==ORDER_TYPE_BUY_STOP ?
                 desired<=old-step+TickSize()*0.1 : desired>=old+step-TickSize()*0.1);
   if(!improve) return;
   if((int)(TimeCurrent()-g_lastModifyAt)<InpMinSecondsPerModify) return;
   g_lastModifyAt=TimeCurrent();
   ResetLastError();
   bool ok=g_trade.OrderModify(keep,desired,sl,tp,ORDER_TIME_GTC,0,0.0);
   if(TradeOK(ok)) g_status="Trailing initial candle STOP";
   else
     {
      TradeError("Modify initial candle STOP");
      g_status="Initial STOP modification rejected";
     }
  }

void StartFirstPosition(const MqlTick &tick)
  {
   if(InpInitialEntry==ENTRY_MANAGE_ONLY)
     {
      g_status="Manage-only; waiting for matching Magic position";
      return;
     }
   if((int)(TimeCurrent()-g_lastEntryTryAt)<InpMinSecondsPerEntryTry) return;
   if(InpMaxSpreadPrice>0.0 && tick.ask-tick.bid>InpMaxSpreadPrice)
     {
      g_status="Spread too wide for first entry";
      return;
     }
   int dir=GetInitialDirection();
   if(dir==0)
     {
      g_status="Waiting for EMA initial-entry confirmation";
      return;
     }
   g_lastEntryTryAt=TimeCurrent();
   double entry=(dir>0 ? tick.ask:tick.bid);
   double sl,tp;
   BuildStops(dir>0,entry,sl,tp);
   ResetLastError();
   bool ok=(dir>0 ? g_trade.Buy(InpLot,_Symbol,0.0,sl,tp,"RTSAR initial BUY")
                  : g_trade.Sell(InpLot,_Symbol,0.0,sl,tp,"RTSAR initial SELL"));
   if(TradeOK(ok))
     {
      MarkCycleStarted();
      g_status=(dir>0 ? "Initial BUY sent":"Initial SELL sent");
      Print("[ReverseTrail] ",g_status);
     }
   else
     {
      TradeError("Initial position entry");
      g_status="Initial entry rejected; check Experts/Journal";
     }
  }

// After a new DEAL_IN, close the former direction immediately. Do NOT
// place a fresh pending order inside DEAL_ADD: account state may still be
// settling. OnTrade/OnTick/OnTimer will install the new reverse pending.
void CloseFormerSideAfterEntry(const ENUM_DEAL_TYPE newDealSide)
  {
   if(newDealSide!=DEAL_TYPE_BUY && newDealSide!=DEAL_TYPE_SELL) return;
   ENUM_POSITION_TYPE incoming=(newDealSide==DEAL_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(ticket)) continue;
      ENUM_POSITION_TYPE oldSide=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(oldSide==incoming) continue;
      ResetLastError();
      bool ok=g_trade.PositionClose(ticket,(ulong)InpDeviationPoints);
      if(!TradeOK(ok))
         TradeError("Close prior direction after new deal #"+IntegerToString((long)ticket));
      else
         PrintFormat("[ReverseTrail] Reverse fill: old opposite position #%I64u closed",ticket);
     }
  }

//+------------------------------------------------------------------+
//| Place/slide exactly one opposite STOP; NEVER move it backwards.  |
//+------------------------------------------------------------------+
void EnsureOppositePending(const ENUM_POSITION_TYPE side,const MqlTick &tick)
  {
   ENUM_ORDER_TYPE required=(side==POSITION_TYPE_BUY ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   ulong keep=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(ticket)) continue;
      ENUM_ORDER_TYPE typ=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(typ==required && keep==0)
         keep=ticket;
      else
        {
         ResetLastError();
         bool ok=g_trade.OrderDelete(ticket);
         if(!TradeOK(ok)) TradeError("Remove stale/duplicate pending");
        }
     }

   // Opposite STOP immediately: try exact position entry if broker permits.
   // If entry is not legal yet, use closest safe 30-pip live-price trailing.
   // Once entry becomes legal, snap to entry, then trail beyond it.
   double dist=ReverseDistance();
   double minD=BrokerMinDistance();
   double limitSell=PriceDown(tick.bid-minD);
   double limitBuy=PriceUp(tick.ask+minD);
   double desired=(required==ORDER_TYPE_SELL_STOP ?
                   PriceDown(tick.bid-dist):PriceUp(tick.ask+dist));
   double positionEntry=0.0;
   ENUM_POSITION_TYPE actualSide=side;
   int pc=0;
   ulong pos=NewestPosition(actualSide,pc);
   if(pos!=0 && PositionSelectByTicket(pos))
      positionEntry=PositionGetDouble(POSITION_PRICE_OPEN);
   bool entryEligible=false;
   if(InpReverseStartAtEntry && positionEntry>0.0)
     {
      if(required==ORDER_TYPE_SELL_STOP && positionEntry<=limitSell)
        {
         entryEligible=true;
         desired=PriceDown(MathMax(desired,positionEntry));
        }
      if(required==ORDER_TYPE_BUY_STOP && positionEntry>=limitBuy)
        {
         entryEligible=true;
         desired=PriceUp(MathMin(desired,positionEntry));
        }
     }
   if(required==ORDER_TYPE_SELL_STOP) desired=PriceDown(MathMin(desired,limitSell));
   else                               desired=PriceUp(MathMax(desired,limitBuy));
   double sl,tp;
   BuildStops(required==ORDER_TYPE_BUY_STOP,desired,sl,tp);

   if(keep==0)
     {
      ResetLastError();
      bool ok=(required==ORDER_TYPE_SELL_STOP ?
               g_trade.SellStop(InpLot,desired,_Symbol,sl,tp,ORDER_TIME_GTC,0,"RTSAR reverse SELL") :
               g_trade.BuyStop(InpLot,desired,_Symbol,sl,tp,ORDER_TIME_GTC,0,"RTSAR reverse BUY"));
      if(TradeOK(ok))
        {
         PrintFormat("[ReverseTrail] New reverse %s at %.*f",EnumToString(required),_Digits,desired);
         g_status=(entryEligible ? "Reverse STOP at entry/30-pip trail" :
                                 "Reverse STOP 30 pips (entry not broker-legal yet)");
        }
      else
        {
         TradeError("Place reverse pending");
         g_status="Reverse pending rejected! Check Experts/Journal";
        }
      return;
     }

   if(!OrderSelect(keep)) return;
   double old=OrderGetDouble(ORDER_PRICE_OPEN);
   double requiredStep=MathMax(InpTrailingStepPrice,TickSize());
   bool better=(required==ORDER_TYPE_SELL_STOP ? desired>old+requiredStep-TickSize()*0.1
                                              : desired<old-requiredStep+TickSize()*0.1);
   if(!better) return;
   if((int)(TimeCurrent()-g_lastModifyAt)<InpMinSecondsPerModify) return;
   g_lastModifyAt=TimeCurrent();
   ResetLastError();
   bool ok=g_trade.OrderModify(keep,desired,sl,tp,ORDER_TIME_GTC,0,0.0);
   if(TradeOK(ok))
     {
      g_status="Trailing opposite STOP";
     }
   else
     {
      TradeError("Modify reverse STOP");
      g_status="Reverse STOP modify failed; old order remains";
     }
  }

//+------------------------------------------------------------------+
//| Main position / reverse order state machine                      |
//+------------------------------------------------------------------+
void ProcessCycle()
  {
   if(g_processing) return;
   g_processing=true;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0.0 || tick.bid<=0.0)
     {
      g_status="No market quote";
      g_processing=false;
      return;
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      g_status="AutoTrading or trading permission disabled";
      g_processing=false;
      return;
     }

   int day=TodayStart();
   if(g_haltedToday && g_haltedDay!=day)
     {
      g_haltedToday=false;
      g_cycleStarted=false; // Daily-stop expiry begins a new cycle.
      if(!MQLInfoInteger(MQL_TESTER))
        {
         GlobalVariableDel(g_startedKey);
         GlobalVariableDel(g_dailyHaltKey);
        }
     }
   CheckDailyHalt();
   if(g_haltedToday)
     {
      CancelAllPending();
      CloseAllPositions();
      g_status="DAILY HALT (resets next broker day)";
      g_processing=false;
      return;
     }

   ENUM_POSITION_TYPE side=POSITION_TYPE_BUY;
   int count=0;
   ulong latest=NewestPosition(side,count);
   if(latest!=0)
     {
      MarkCycleStarted();
      if(count>1)
        {
         CloseAllExcept(latest);
         ENUM_POSITION_TYPE refreshed=side;
         int remaining=0;
         ulong stillNewest=NewestPosition(refreshed,remaining);
         if(remaining!=1 || stillNewest==0)
           {
            g_status="Closing previous positions; retrying";
            g_processing=false;
            return;
           }
         side=refreshed;
        }
      EnsureOppositePending(side,tick);
     }
   else
     {
      // Flat can have a first-entry pending STOP. Keep/trail it until filled.
      if(g_cycleStarted && !InpRestartAfterFlat)
        {
         CancelAllPending();
         g_status="Cycle completed; auto-restart disabled";
        }
      else if(InpInitialEntry==ENTRY_CANDLE_STOP)
         EnsureFirstCandlePending(tick);
      else
        {
         CancelAllPending(); // Market-first modes must not leave stale orders.
         StartFirstPosition(tick);
        }
     }
   g_processing=false;
  }

//+------------------------------------------------------------------+
//| Minimal on-chart state                                           |
//+------------------------------------------------------------------+
void ShowStatus()
  {
   ENUM_POSITION_TYPE side=POSITION_TYPE_BUY;
   int count=0;
   ulong ticket=NewestPosition(side,count);
   string positionText=(ticket==0 ? "FLAT" :
                        (side==POSITION_TYPE_BUY ? "BUY":"SELL"));
   Comment("ReverseTrail SAR (ENTRY PROTECT 30 PIP) v1.20\n",
           "Symbol: ",_Symbol," | Magic: ",InpMagic,"\n",
           "Position: ",positionText," | Open positions: ",count,"\n",
           "Distance: ",DoubleToString(ReverseDistance(),_Digits),
           " | Step: ",DoubleToString(InpTrailingStepPrice,_Digits),"\n",
           "Status: ",g_status,"\n",
           "Hedging accounts only | Demo / Tester first");
  }

int OnInit()
  {
   if(InpMagic<=0 || InpLot<=0.0 || InpFixedDistancePrice<=0.0 ||
      InpTrailingStepPrice<=0.0 || InpTrailingPips<=0.0 || InpPipSizePrice<=0.0 ||
      InpATRPeriod<2 || InpATRMultiplier<=0.0 ||
      InpMinDistancePrice<=0.0 || InpMaxDistancePrice<InpMinDistancePrice ||
      InpHardSLDistancePrice<0.0 || InpTakeProfitDistancePrice<0.0 ||
      InpDailyProfitMoney<0.0 || InpDailyLossMoney<0.0 ||
      InpMinSecondsPerModify<0 || InpMinSecondsPerEntryTry<0 ||
      InpMaxSpreadPrice<0.0 || InpDeviationPoints<0 ||
      InpFastEMA<2 || InpSlowEMA<=InpFastEMA ||
       InpCandleEntryBufferPrice<0.0 || InpCandleRepriceStepPrice<=0.0)
     {
      Print("[ReverseTrail] Invalid Inputs; inspect limits and distances.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("[ReverseTrail] SAFETY: hedging account required. Netting accounts do not reverse with equal-size opposing pending orders.");
      return INIT_FAILED;
     }

   double volumeMin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double volumeMax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(InpLot<volumeMin-1e-9 || InpLot>volumeMax+1e-9 ||
      volumeStep<=0.0 || MathAbs(InpLot/volumeStep-MathRound(InpLot/volumeStep))>1e-6)
     {
      PrintFormat("[ReverseTrail] InpLot %.3f violates broker min/max/step: %.3f / %.3f / %.3f",
                  InpLot,volumeMin,volumeMax,volumeStep);
      return INIT_PARAMETERS_INCORRECT;
     }

   long allowed=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((allowed & SYMBOL_ORDER_STOP)==0)
     {
      Print("[ReverseTrail] Broker symbol does not allow BuyStop/SellStop orders.");
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_atrHandle=iATR(_Symbol,InpATRTF,InpATRPeriod);
   if(InpDistanceMode==DISTANCE_ATR && g_atrHandle==INVALID_HANDLE)
     {
      Print("[ReverseTrail] Failed to create ATR handle.");
      return INIT_FAILED;
     }
   if(InpInitialEntry==ENTRY_EMA_TREND)
     {
      g_emaFastHandle=iMA(_Symbol,InpSignalTF,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
      g_emaSlowHandle=iMA(_Symbol,InpSignalTF,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
      if(g_emaFastHandle==INVALID_HANDLE || g_emaSlowHandle==INVALID_HANDLE)
        {
         Print("[ReverseTrail] Failed to create EMA handles.");
         return INIT_FAILED;
        }
     }

   string statePrefix="RTSAR_"+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"_"+
                      _Symbol+"_"+IntegerToString(InpMagic);
   g_startedKey=statePrefix+"_started";
   g_dailyHaltKey=statePrefix+"_halt";
   if(MQLInfoInteger(MQL_TESTER))
     {
      // Every Strategy Tester pass starts with clean state.
      g_cycleStarted=false;
      g_haltedToday=false;
     }
   else
     {
      if(InpResetCycleStateOnInit)
        {
         // Use only when flat with no old orders, and set back to FALSE afterwards.
         GlobalVariableDel(g_startedKey);
         Print("[ReverseTrail] Stored cycle-start flag reset on init.");
        }
      if(GlobalVariableCheck(g_dailyHaltKey) &&
         (int)GlobalVariableGet(g_dailyHaltKey)!=TodayStart())
        {
         // A prior daily halt expires on the next broker day.
         GlobalVariableDel(g_dailyHaltKey);
         GlobalVariableDel(g_startedKey);
        }
      g_cycleStarted=GlobalVariableCheck(g_startedKey) && GlobalVariableGet(g_startedKey)>0.0;
      g_haltedToday=GlobalVariableCheck(g_dailyHaltKey) &&
                    (int)GlobalVariableGet(g_dailyHaltKey)==TodayStart();
      if(g_haltedToday) g_haltedDay=TodayStart();
     }
   EventSetTimer(1);
   g_status="EA initialized (standalone candle-entry)";
   Print("[ReverseTrail] Entry protection 30-pip v1.20 initialized for ",_Symbol,". Hedging verified; independent of Katarina AI.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_emaFastHandle!=INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle!=INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   Comment("");
   // IMPORTANT: do NOT auto-delete live broker orders on chart removal.
   // To stop ALL trades, disable AutoTrading and cancel this EA's orders manually.
  }

void OnTick()
  {
   ProcessCycle();
   ShowStatus();
  }

void OnTimer()
  {
   ProcessCycle();
   ShowStatus();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // Promptly close the old direction when the reverse pending order fills.
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic) return;
   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) return;
   MarkCycleStarted();
   ENUM_DEAL_TYPE dealSide=(ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   CloseFormerSideAfterEntry(dealSide);
   // Send reverse pending in the same trade callback; retry on tick/timer.
   ProcessCycle();
  }

void OnTrade()
  {
   ProcessCycle();
  }
//+------------------------------------------------------------------+