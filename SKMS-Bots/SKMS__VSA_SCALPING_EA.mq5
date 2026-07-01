//+------------------------------------------------------------------+
//|  SK Market Structure EA v2                                       |
//|  XAUUSD M1 - Trend Following CAB Strategy                       |
//+------------------------------------------------------------------+
#property copyright "SK"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
enum LOT_MODE
{
   FIXED_LOT,   // Fixed Lot Size
   FIXED_RISK   // Fixed Risk (Account Currency)
};

input LOT_MODE LotMode            = FIXED_LOT; // Lot Mode
input double   FixedLot           = 0.05;       // Fixed Lot Size
input double   RiskAmount         = 50.0;       // Risk Amount (Account Currency)
input int      MagicNumber        = 12345;
input double   SL_Buffer          = 1.0;        // SL Buffer in price (10 pips XAUUSD)
input double   RR_TP              = 2.0;        // Risk:Reward for TP (e.g. 2 = 1:2)
input bool     UseBE              = true;       // Break Even (ON/OFF)
input double   BE_RR              = 1.0;        // Break Even at RR (e.g. 1 = 1:1)
input int      WaitForBOS         = 1;          // BOS count after CHOCH (0 = no wait)
input bool     UseVolumeConfirm   = false;      // Volume Confirmation (ON/OFF)
input bool     UseSMAConfirm      = false;      // SMA Confirmation (ON/OFF)
input int      SMA_Fast           = 200;        // Fast SMA Period
input int      SMA_Slow           = 700;        // Slow SMA Period

CTrade trade;

//+------------------------------------------------------------------+
//|  ENUMS & STRUCTS                                                |
//+------------------------------------------------------------------+
enum BIAS { BULLISH, BEARISH };

struct Pivot
{
   double price;
   bool   confirmed;
   int    barIndex;
   Pivot() : price(0), confirmed(false), barIndex(0) {}
   Pivot(double p, bool c=false, int b=0) : price(p), confirmed(c), barIndex(b) {}
};

struct IndependentBar
{
   double level;
   int    barIndex;
   IndependentBar() : level(0), barIndex(0) {}
   IndependentBar(double l, int b=0) : level(l), barIndex(b) {}
};

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Indicator                                       |
//+------------------------------------------------------------------+
BIAS   swingBias;
Pivot  lastHigh, lastLow;
Pivot  confirmHigh, confirmLow;
IndependentBar lastIndBullBar, lastIndBearBar;
bool   retracementStarted;
double retracementStartLevel;

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Structure Tracking                              |
//+------------------------------------------------------------------+
int    bosCountAfterChoch;      // how many BOS happened after last CHOCH
bool   chochHappened;           // at least one CHOCH has occurred
BIAS   chochDirection;          // direction of last CHOCH (for trade direction)

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Trade Setup                                     |
//+------------------------------------------------------------------+
bool   setupActive;             // trade setup is live
BIAS   setupDirection;          // BUY or SELL
double cabHigh;                 // CAB candle high
double cabLow;                  // CAB candle low
double cabVolume;               // CAB candle volume (to compare for updates)
double absoluteSlPoint;         // current SL reference (CAB low for buy, high for sell)
double trackedEntry;            // tracked high (buy) or low (sell) for entry trigger
double entryPrice;              // actual entry price
double slPrice;                 // actual SL price
double tpPrice;                 // actual TP price
double bePrice;                 // break even price
bool   inTrade;                 // currently in a trade
bool   bePlaced;                // break even already set

//--- Retracement window
int    retracementStartBarIdx;  // bar index when retracement started (= lastHigh/lastLow barIndex)

//--- Bar tracking
datetime lastBarTime;
int      totalBars;

//--- SMA handles
int      hSMA_Fast;
int      hSMA_Slow;

//+------------------------------------------------------------------+
//|  CALCULATE LOT SIZE                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
{
   if(LotMode == FIXED_LOT) return FixedLot;

   double slDist = MathAbs(entry - sl);
   if(slDist <= 0) { Print("SL dist=0, fallback to fixed lot"); return FixedLot; }

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) { Print("Tick info error, fallback"); return FixedLot; }

   double valuePerLot = tickValue / tickSize;
   double lot = RiskAmount / (slDist * valuePerLot);

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   Print("Risk lot: dist=", slDist, " lot=", lot,
         " risk=$", NormalizeDouble(lot * slDist * valuePerLot, 2));
   return lot;
}

//+------------------------------------------------------------------+
//|  HELPERS - Market Structure                                     |
//+------------------------------------------------------------------+
void GetLowestLow(int fromIdx, int toIdx, double &ll, int &llBar)
{
   ll = DBL_MAX; llBar = fromIdx;
   for(int i = fromIdx; i <= toIdx; i++)
   {
      int ago = totalBars - i;
      if(ago < 0) continue;
      double v = iLow(_Symbol, PERIOD_CURRENT, ago);
      if(v < ll) { ll = v; llBar = i; }
   }
}

void GetHighestHigh(int fromIdx, int toIdx, double &hh, int &hhBar)
{
   hh = -DBL_MAX; hhBar = fromIdx;
   for(int i = fromIdx; i <= toIdx; i++)
   {
      int ago = totalBars - i;
      if(ago < 0) continue;
      double v = iHigh(_Symbol, PERIOD_CURRENT, ago);
      if(v > hh) { hh = v; hhBar = i; }
   }
}

//+------------------------------------------------------------------+
//|  SMA BIAS                                                       |
//+------------------------------------------------------------------+
int GetSMABias()
{
   if(!UseSMAConfirm) return 0;
   double f[1], s[1];
   if(CopyBuffer(hSMA_Fast, 0, 1, 1, f) <= 0) return 0;
   if(CopyBuffer(hSMA_Slow, 0, 1, 1, s) <= 0) return 0;
   if(f[0] > s[0]) return  1;
   if(f[0] < s[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//|  IS TRADE OPEN BY THIS EA                                      |
//+------------------------------------------------------------------+
bool IsTradeOpen()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol)
         if((int)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

//+------------------------------------------------------------------+
//|  RESET SETUP                                                    |
//+------------------------------------------------------------------+
void ResetSetup()
{
   setupActive      = false;
   cabHigh          = 0;
   cabLow           = 0;
   cabVolume        = 0;
   absoluteSlPoint  = 0;
   trackedEntry     = 0;
   retracementStartBarIdx = 0;
}

//+------------------------------------------------------------------+
//|  RESET TRADE STATE                                              |
//+------------------------------------------------------------------+
void ResetTradeState()
{
   inTrade   = false;
   bePlaced  = false;
   entryPrice = slPrice = tpPrice = bePrice = 0;
}

//+------------------------------------------------------------------+
//|  INIT                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   hSMA_Fast = iMA(_Symbol, PERIOD_CURRENT, SMA_Fast, 0, MODE_SMA, PRICE_CLOSE);
   hSMA_Slow = iMA(_Symbol, PERIOD_CURRENT, SMA_Slow, 0, MODE_SMA, PRICE_CLOSE);
   if(hSMA_Fast == INVALID_HANDLE || hSMA_Slow == INVALID_HANDLE)
   { Print("SMA handle error"); return INIT_FAILED; }

   // Indicator state
   swingBias             = BULLISH;
   retracementStarted    = false;
   retracementStartLevel = 0;

   // Structure tracking
   bosCountAfterChoch    = 0;
   chochHappened         = false;
   chochDirection        = BULLISH;

   // Setup state
   ResetSetup();
   ResetTradeState();

   totalBars   = 0;
   lastBarTime = 0;

   double o0 = iOpen(_Symbol,  PERIOD_CURRENT, 0);
   double c0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   double h0 = iHigh(_Symbol,  PERIOD_CURRENT, 0);
   double l0 = iLow(_Symbol,   PERIOD_CURRENT, 0);

   if(c0 > o0)
   { swingBias = BULLISH; lastHigh = Pivot(h0,false,0); confirmLow  = Pivot(l0,true,0); }
   else
   { swingBias = BEARISH; lastLow  = Pivot(l0,false,0); confirmHigh = Pivot(h0,true,0); }

   Print("SKMS EA v2 started | WaitForBOS=", WaitForBOS,
         " | LotMode=", EnumToString(LotMode));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  ON TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   double O = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double C = iClose(_Symbol, PERIOD_CURRENT, 1);
   double H = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double L = iLow(_Symbol,   PERIOD_CURRENT, 1);
   long   V = iVolume(_Symbol, PERIOD_CURRENT, 1);

   totalBars++;
   int barIdx   = totalBars;
   double prevC = iClose(_Symbol, PERIOD_CURRENT, 2);

   ProcessIndicatorLogic(O, C, H, L, prevC, barIdx, V);
   ProcessSetupTracking(O, C, H, L, V);
   ProcessBreakEven();
}

//+------------------------------------------------------------------+
//|  INDICATOR LOGIC (market structure - same as v1)               |
//+------------------------------------------------------------------+
void ProcessIndicatorLogic(double O, double C, double H, double L,
                            double prevC, int barIdx, long V)
{
   //--- Update last high / last low
   if(swingBias == BULLISH)
   {
      if(C > lastHigh.price && !lastHigh.confirmed)
      {
         lastHigh = Pivot(H, false, barIdx);
         double ib = (O != prevC) ? prevC : L;
         lastIndBullBar = IndependentBar(ib, barIdx);
         retracementStartLevel = ib;
         retracementStarted    = false;
      }
      else if(H > lastHigh.price && C < lastHigh.price && lastHigh.confirmed)
         lastHigh.price = H;
      else if(H > lastHigh.price && C < lastHigh.price && !lastHigh.confirmed)
         lastHigh = Pivot(H, false, barIdx);
   }
   else
   {
      if(C < lastLow.price && !lastLow.confirmed)
      {
         lastLow = Pivot(L, false, barIdx);
         double ib = (O != prevC) ? prevC : H;
         lastIndBearBar = IndependentBar(ib, barIdx);
         retracementStartLevel = ib;
         retracementStarted    = false;
      }
      else if(L < lastLow.price && C > lastLow.price && lastLow.confirmed)
         lastLow.price = L;
      else if(L < lastLow.price && C > lastLow.price && !lastLow.confirmed)
         lastLow = Pivot(L, false, barIdx);
   }

   //--- Update confirm high / confirm low
   if(swingBias == BULLISH)
   {
      if(confirmLow.price > 0 && L < confirmLow.price && C > confirmLow.price && confirmLow.confirmed)
         confirmLow.price = L;
      else if(confirmLow.price > 0 && L < confirmLow.price && C > confirmLow.price && !confirmLow.confirmed)
         confirmLow = Pivot(L, false, barIdx);
   }
   else
   {
      if(confirmHigh.price > 0 && H > confirmHigh.price && C < confirmHigh.price && confirmHigh.confirmed)
         confirmHigh.price = H;
      else if(confirmHigh.price > 0 && H > confirmHigh.price && C < confirmHigh.price && !confirmHigh.confirmed)
         confirmHigh = Pivot(H, false, barIdx);
   }

   //--- Retracement start check
   if(!retracementStarted && retracementStartLevel > 0)
   {
      if(swingBias == BULLISH)
      {
         if(C < retracementStartLevel)
         { retracementStarted = true; retracementStartLevel = 0; lastHigh.confirmed = true; }
         else if(L < retracementStartLevel)
            retracementStartLevel = L;
      }
      else
      {
         if(C > retracementStartLevel)
         { retracementStarted = true; retracementStartLevel = 0; lastLow.confirmed = true; }
         else if(H > retracementStartLevel)
            retracementStartLevel = H;
      }
   }

   //--- BOS / CHOCH detection
   if(retracementStarted)
   {
      if(swingBias == BULLISH)
      {
         // BEARISH CHOCH
         if(confirmLow.price > 0 && C < confirmLow.price && confirmLow.confirmed)
         {
            Print("Bearish CHOCH at ", confirmLow.price);

            double hh; int hhBar;
            GetHighestHigh(confirmLow.barIndex, barIdx, hh, hhBar);
            confirmHigh = Pivot(hh, true, hhBar);

            // Structure flipped to bearish → reset BOS count, record CHOCH
            chochHappened      = true;
            chochDirection     = BEARISH;
            bosCountAfterChoch = 0;

            // Cancel any active buy setup — structure flipped
            if(setupActive && setupDirection == BULLISH)
            {
               Print("Buy setup cancelled: Bearish CHOCH flipped structure");
               ResetSetup();
            }

            swingBias             = BEARISH;
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = H;
         }
         // BULLISH BOS
         else if(lastHigh.price > 0 && C > lastHigh.price && lastHigh.confirmed)
         {
            Print("Bullish BOS at ", lastHigh.price);

            if(chochHappened && chochDirection == BULLISH)
               bosCountAfterChoch++;

            double ll; int llBar;
            GetLowestLow(lastHigh.barIndex, barIdx, ll, llBar);
            confirmLow            = Pivot(ll, true, llBar);
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = L;
         }
      }
      else // BEARISH structure
      {
         // BULLISH CHOCH
         if(confirmHigh.price > 0 && C > confirmHigh.price && confirmHigh.confirmed)
         {
            Print("Bullish CHOCH at ", confirmHigh.price);

            double ll; int llBar;
            GetLowestLow(confirmHigh.barIndex, barIdx, ll, llBar);
            confirmLow = Pivot(ll, true, llBar);

            chochHappened      = true;
            chochDirection     = BULLISH;
            bosCountAfterChoch = 0;

            // Cancel any active sell setup — structure flipped
            if(setupActive && setupDirection == BEARISH)
            {
               Print("Sell setup cancelled: Bullish CHOCH flipped structure");
               ResetSetup();
            }

            swingBias             = BULLISH;
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = L;
         }
         // BEARISH BOS
         else if(lastLow.price > 0 && C < lastLow.price && lastLow.confirmed)
         {
            Print("Bearish BOS at ", lastLow.price);

            if(chochHappened && chochDirection == BEARISH)
               bosCountAfterChoch++;

            double hh; int hhBar;
            GetHighestHigh(lastLow.barIndex, barIdx, hh, hhBar);
            confirmHigh           = Pivot(hh, true, hhBar);
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = H;
         }
      }
   }
   else
   {
      // Direct confirmHigh/Low break (no retracement)
      if(swingBias == BULLISH && confirmLow.price > 0 && C < confirmLow.price)
      {
         // Opposite CHOCH → cancel sell setups handled separately
         if(setupActive && setupDirection == BULLISH) ResetSetup();
         swingBias = BEARISH;
         confirmHigh = lastHigh; confirmHigh.confirmed = true;
         lastLow = confirmLow;
         confirmLow = Pivot(0,false,0); lastHigh = Pivot(0,false,0);
         lastIndBullBar = IndependentBar(L, totalBars);
         retracementStartLevel = L;
         retracementStarted    = false;
         chochHappened = true; chochDirection = BEARISH; bosCountAfterChoch = 0;
      }
      else if(swingBias == BEARISH && confirmHigh.price > 0 && C > confirmHigh.price)
      {
         if(setupActive && setupDirection == BEARISH) ResetSetup();
         swingBias = BULLISH;
         confirmLow = lastLow; confirmLow.confirmed = true;
         lastHigh = confirmHigh;
         confirmHigh = Pivot(0,false,0); lastLow = Pivot(0,false,0);
         lastIndBearBar = IndependentBar(H, totalBars);
         retracementStartLevel = H;
         retracementStarted    = false;
         chochHappened = true; chochDirection = BULLISH; bosCountAfterChoch = 0;
      }
   }
}

//+------------------------------------------------------------------+
//|  SETUP TRACKING                                                 |
//+------------------------------------------------------------------+
void ProcessSetupTracking(double O, double C, double H, double L, long V)
{
   if(IsTradeOpen()) return;

   //================================================================
   // CHECK IF WE CAN LOOK FOR A SETUP
   // Conditions:
   // 1. At least one CHOCH has happened
   // 2. BOS count >= WaitForBOS
   // 3. Retracement has started
   // 4. No setup already active (or update active setup)
   //================================================================
   bool bosConditionMet = chochHappened && (bosCountAfterChoch >= WaitForBOS);

   if(!bosConditionMet) return;
   if(!retracementStarted) return;

   // SMA filter
   int smaBias = GetSMABias();
   bool canBuy  = (swingBias == BULLISH) && (smaBias >= 0);
   bool canSell = (swingBias == BEARISH) && (smaBias <= 0);

   if(!canBuy && !canSell) return;

   //================================================================
   // BULLISH STRUCTURE → Look for BUY setup
   //================================================================
   if(swingBias == BULLISH && canBuy)
   {
      // Retracement window: lastHigh.barIndex to current bar
      // Look for CAB = highest volume bearish candle in this range

      bool isBearish = C < O;

      if(!setupActive)
      {
         // First time: if this candle is bearish, it's the first CAB candidate
         if(isBearish && V > 0)
         {
            // Start of retracement — record this bar as CAB window start
            retracementStartBarIdx = lastHigh.barIndex;

            // Scan retracement window for highest volume bearish candle
            double maxVol    = -1;
            double cabH      = 0, cabL = 0;
            for(int i = lastHigh.barIndex; i <= totalBars; i++)
            {
               int ago    = totalBars - i;
               double bO  = iOpen(_Symbol,  PERIOD_CURRENT, ago);
               double bC  = iClose(_Symbol, PERIOD_CURRENT, ago);
               double bH  = iHigh(_Symbol,  PERIOD_CURRENT, ago);
               double bL  = iLow(_Symbol,   PERIOD_CURRENT, ago);
               long   bV  = iVolume(_Symbol, PERIOD_CURRENT, ago);
               if(bC < bO && bV > maxVol)
               { maxVol = bV; cabH = bH; cabL = bL; }
            }

            if(cabH > 0)
            {
               setupActive     = true;
               setupDirection  = BULLISH;
               cabHigh         = cabH;
               cabLow          = cabL;
               cabVolume       = maxVol;
               absoluteSlPoint = cabL;
               trackedEntry    = cabH;
               Print("BUY Setup activated | CAB High=", cabH, " CAB Low=", cabL,
                     " Vol=", maxVol);
            }
         }
      }
      else if(setupActive && setupDirection == BULLISH)
      {
         // Setup already active — update CAB if new higher volume bearish candle appears
         if(C < O && V > cabVolume)
         {
            cabHigh         = H;
            cabLow          = L;
            cabVolume       = V;
            absoluteSlPoint = L;
            trackedEntry    = H;
            Print("CAB updated (higher vol) | New CAB High=", H, " Low=", L);
         }

         // Update absoluteSlPoint if CAB low is swept or broken
         if(L < absoluteSlPoint)
         {
            absoluteSlPoint = L;
            Print("AbsoluteSL updated to ", L);
         }

         // Update trackedEntry if CAB high swept (wick above, close below)
         if(H > trackedEntry && C < trackedEntry)
         {
            trackedEntry = H;
            Print("TrackedEntry (high) updated to ", H);
         }

         // ENTRY: bullish candle closes above trackedEntry
         if(C > trackedEntry && C > O)
         {
            double sl  = absoluteSlPoint - SL_Buffer;
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double lot = CalculateLotSize(ask, sl);
            double riskDist = MathAbs(ask - sl);
            double tp  = ask + riskDist * RR_TP;
            double be  = ask + riskDist * BE_RR;

            Print("BUY Entry | Ask=", ask, " SL=", sl, " TP=", tp,
                  " BE=", be, " Lot=", lot);

            if(trade.Buy(lot, _Symbol, 0, sl, tp, "BUY CAB"))
            {
               Print("Buy placed OK");
               entryPrice = ask;
               slPrice    = sl;
               tpPrice    = tp;
               bePrice    = be;
               inTrade    = true;
               bePlaced   = false;
               ResetSetup();
            }
            else
               Print("Buy failed: ", trade.ResultRetcode(), " ",
                     trade.ResultRetcodeDescription());
         }
      }
   }

   //================================================================
   // BEARISH STRUCTURE → Look for SELL setup
   //================================================================
   else if(swingBias == BEARISH && canSell)
   {
      bool isBullish = C > O;

      if(!setupActive)
      {
         if(isBullish && V > 0)
         {
            retracementStartBarIdx = lastLow.barIndex;

            // Scan retracement window for highest volume bullish candle
            double maxVol = -1;
            double cabH   = 0, cabL = 0;
            for(int i = lastLow.barIndex; i <= totalBars; i++)
            {
               int ago   = totalBars - i;
               double bO = iOpen(_Symbol,  PERIOD_CURRENT, ago);
               double bC = iClose(_Symbol, PERIOD_CURRENT, ago);
               double bH = iHigh(_Symbol,  PERIOD_CURRENT, ago);
               double bL = iLow(_Symbol,   PERIOD_CURRENT, ago);
               long   bV = iVolume(_Symbol, PERIOD_CURRENT, ago);
               if(bC > bO && bV > maxVol)
               { maxVol = bV; cabH = bH; cabL = bL; }
            }

            if(cabL > 0)
            {
               setupActive     = true;
               setupDirection  = BEARISH;
               cabHigh         = cabH;
               cabLow          = cabL;
               cabVolume       = maxVol;
               absoluteSlPoint = cabH;
               trackedEntry    = cabL;
               Print("SELL Setup activated | CAB High=", cabH, " CAB Low=", cabL,
                     " Vol=", maxVol);
            }
         }
      }
      else if(setupActive && setupDirection == BEARISH)
      {
         // Update CAB if new higher volume bullish candle appears
         if(C > O && V > cabVolume)
         {
            cabHigh         = H;
            cabLow          = L;
            cabVolume       = V;
            absoluteSlPoint = H;
            trackedEntry    = L;
            Print("CAB updated (higher vol) | New CAB High=", H, " Low=", L);
         }

         // Update absoluteSlPoint if CAB high swept or broken
         if(H > absoluteSlPoint)
         {
            absoluteSlPoint = H;
            Print("AbsoluteSL updated to ", H);
         }

         // Update trackedEntry if CAB low swept (wick below, close above)
         if(L < trackedEntry && C > trackedEntry)
         {
            trackedEntry = L;
            Print("TrackedEntry (low) updated to ", L);
         }

         // ENTRY: bearish candle closes below trackedEntry
         if(C < trackedEntry && C < O)
         {
            double sl  = absoluteSlPoint + SL_Buffer;
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double lot = CalculateLotSize(bid, sl);
            double riskDist = MathAbs(bid - sl);
            double tp  = bid - riskDist * RR_TP;
            double be  = bid - riskDist * BE_RR;

            Print("SELL Entry | Bid=", bid, " SL=", sl, " TP=", tp,
                  " BE=", be, " Lot=", lot);

            if(trade.Sell(lot, _Symbol, 0, sl, tp, "SELL CAB"))
            {
               Print("Sell placed OK");
               entryPrice = bid;
               slPrice    = sl;
               tpPrice    = tp;
               bePrice    = be;
               inTrade    = true;
               bePlaced   = false;
               ResetSetup();
            }
            else
               Print("Sell failed: ", trade.ResultRetcode(), " ",
                     trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  BREAK EVEN MANAGEMENT                                          |
//+------------------------------------------------------------------+
void ProcessBreakEven()
{
   if(!UseBE || !inTrade || bePlaced) return;
   if(!IsTradeOpen()) { ResetTradeState(); return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY && bid >= bePrice)
      {
         if(trade.PositionModify(ticket, entryPrice, tpPrice))
         { Print("BE set: SL moved to entry ", entryPrice); bePlaced = true; }
      }
      else if(type == POSITION_TYPE_SELL && ask <= bePrice)
      {
         if(trade.PositionModify(ticket, entryPrice, tpPrice))
         { Print("BE set: SL moved to entry ", entryPrice); bePlaced = true; }
      }
   }
}

//+------------------------------------------------------------------+
//|  DEINIT                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hSMA_Fast);
   IndicatorRelease(hSMA_Slow);
   Print("SKMS EA v2 removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
