//+------------------------------------------------------------------+
//|  SK Market Structure EA                                          |
//|  XAUUSD M1 - Liquidity Sweep Strategy                           |
//+------------------------------------------------------------------+
#property copyright "SK"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
enum LOT_MODE
{
   FIXED_LOT,    // Fixed Lot Size
   FIXED_RISK    // Fixed Risk (Account Currency)
};

input LOT_MODE   LotMode      = FIXED_LOT;  // Lot Mode
input double     FixedLot     = 0.05;        // Fixed Lot Size
input double     RiskAmount   = 50.0;        // Risk Amount (Account Currency)
input int        MagicNumber  = 12345;
input double     SL_Buffer    = 1.0;         // SL Buffer (10 pips for XAUUSD)
input bool       UseVolumeConfirmation = false; // Volume Confirmation (ON/OFF)

//--- Trade object
CTrade trade;

//+------------------------------------------------------------------+
//|  ENUMS                                                           |
//+------------------------------------------------------------------+
enum BIAS { BULLISH, BEARISH };

//+------------------------------------------------------------------+
//|  STRUCTS                                                         |
//+------------------------------------------------------------------+
struct Pivot
{
   double price;
   bool   confirmed;
   int    barIndex;

   Pivot() : price(0), confirmed(false), barIndex(0) {}
   Pivot(double p, bool c = false, int b = 0) : price(p), confirmed(c), barIndex(b) {}
};

struct IndependentBar
{
   double level;
   int    barIndex;

   IndependentBar() : level(0), barIndex(0) {}
   IndependentBar(double l, int b = 0) : level(l), barIndex(b) {}
};

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Indicator Variables                             |
//+------------------------------------------------------------------+
BIAS   swingBias;
Pivot  lastHigh, lastLow;
Pivot  confirmHigh, confirmLow;
IndependentBar lastIndBullBar, lastIndBearBar;
bool   retracementStarted;
double retracementStartLevel;

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Strategy Variables                              |
//+------------------------------------------------------------------+
bool   bearishChochActive;
bool   bullishChochActive;
bool   isBocNearToSweep;
double bocHigh;
double bocLow;
double chochLevel;
double tpLevel;
double trackedBocHigh;
double trackedBocLow;
double absoluteSlPoint;
int    independentBarsAfterBoc;
int    independentBarsAllowed;

//--- Bar tracking
datetime lastBarTime;
int      totalBars;

//+------------------------------------------------------------------+
//|  CALCULATE LOT SIZE                                             |
//|  If FIXED_LOT  → return FixedLot                               |
//|  If FIXED_RISK → Risk Amount / (SL distance × contract value)  |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double slPrice)
{
   if(LotMode == FIXED_LOT)
      return FixedLot;

   // Fixed Risk calculation
   double slDistance = MathAbs(entryPrice - slPrice); // in price (e.g. 1.5 for gold)
   if(slDistance <= 0)
   {
      Print("SL distance is 0, using fixed lot fallback");
      return FixedLot;
   }

   // For XAUUSD: 1 lot = 100 oz, tick size = 0.01, tick value = $1
   // So 1 lot × $1 move = $100 profit/loss
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
   {
      Print("Could not get tick info, using fixed lot fallback");
      return FixedLot;
   }

   // Value per lot per 1 unit price move
   double valuePerLotPerPoint = tickValue / tickSize;

   // Lot = RiskAmount / (SL distance × value per lot per point)
   double lotSize = RiskAmount / (slDistance * valuePerLotPerPoint);

   // Normalize to broker's lot step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   Print("Risk-based lot: SL dist=", slDistance, " LotSize=", lotSize,
         " Expected risk=$", NormalizeDouble(lotSize * slDistance * valuePerLotPerPoint, 2));

   return lotSize;
}

//+------------------------------------------------------------------+
//|  HELPERS                                                        |
//+------------------------------------------------------------------+
void GetLowestLow(int fromBarIdx, int toBarIdx, double &lowestLow, int &lowestBarIdx)
{
   lowestLow    = DBL_MAX;
   lowestBarIdx = fromBarIdx;
   for(int i = fromBarIdx; i <= toBarIdx; i++)
   {
      int barsAgo = totalBars - i;
      if(barsAgo < 0) continue;
      double l = iLow(_Symbol, PERIOD_CURRENT, barsAgo);
      if(l < lowestLow) { lowestLow = l; lowestBarIdx = i; }
   }
}

void GetHighestHigh(int fromBarIdx, int toBarIdx, double &highestHigh, int &highestBarIdx)
{
   highestHigh    = -DBL_MAX;
   highestBarIdx  = fromBarIdx;
   for(int i = fromBarIdx; i <= toBarIdx; i++)
   {
      int barsAgo = totalBars - i;
      if(barsAgo < 0) continue;
      double h = iHigh(_Symbol, PERIOD_CURRENT, barsAgo);
      if(h > highestHigh) { highestHigh = h; highestBarIdx = i; }
   }
}

bool ValidateBearishChoch(double o, double c, double h, double l, double choch)
{
   double body = MathAbs(c - o);
   if(body <= 0) return false;
   double lowerWick  = MathMin(o, c) - l;
   bool   cond1      = lowerWick >= body * 0.15;
   double bodyBottom = MathMin(o, c);
   double pctBelow   = MathMax(0.0, choch - bodyBottom) / body;
   bool   cond2      = pctBelow < 0.75;
   return cond1 && cond2;
}

bool ValidateBullishChoch(double o, double c, double h, double l, double choch)
{
   double body = MathAbs(c - o);
   if(body <= 0) return false;
   double upperWick = h - MathMax(o, c);
   bool   cond1     = upperWick >= body * 0.15;
   double bodyTop   = MathMax(o, c);
   double pctAbove  = MathMax(0.0, bodyTop - choch) / body;
   bool   cond2     = pctAbove < 0.75;
   return cond1 && cond2;
}

bool CheckIsBocNearToSweep(double breakoutLevel, double o, double c)
{
   double bodySize = MathAbs(o - c);
   if(bodySize <= 0) return false;
   return MathAbs(c - breakoutLevel) <= bodySize * 0.01;
}

bool CheckIsValidNextIBAfterBoc(double breakoutLevel, double o, double c, double ratio = 0.4)
{
   double bodySize = MathAbs(o - c);
   if(bodySize <= 0) return false;
   return MathAbs(c - breakoutLevel) <= bodySize * ratio;
}

bool CheckIsMomentumCandle(double h, double l, double o, double c, double wickPct = 0.35)
{
   double candleSize = MathAbs(h - l);
   if(candleSize <= 0) return false;
   double wick = (c > o) ? h - c : c - l;
   return wick <= candleSize * wickPct;
}

bool CheckIsSignificantBreakout(double breakoutLevel, double h, double l, double o, double c)
{
   double candleSize = MathAbs(h - l);
   if(candleSize <= 0) return false;
   return MathAbs(c - breakoutLevel) >= candleSize * 0.1;
}

bool IsTradeOpen()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

void ResetBuySetup()
{
   bearishChochActive      = false;
   bocHigh                 = 0;
   bocLow                  = 0;
   trackedBocHigh          = 0;
   trackedBocLow           = 0;
   chochLevel              = 0;
   tpLevel                 = 0;
   absoluteSlPoint         = 0;
   isBocNearToSweep        = false;
   independentBarsAfterBoc = 0;
}

void ResetSellSetup()
{
   bullishChochActive      = false;
   bocHigh                 = 0;
   bocLow                  = 0;
   trackedBocHigh          = 0;
   trackedBocLow           = 0;
   chochLevel              = 0;
   tpLevel                 = 0;
   absoluteSlPoint         = 0;
   isBocNearToSweep        = false;
   independentBarsAfterBoc = 0;
}

//+------------------------------------------------------------------+
//|  INIT                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   swingBias             = BULLISH;
   retracementStarted    = false;
   retracementStartLevel = 0;
   bearishChochActive    = false;
   bullishChochActive    = false;
   isBocNearToSweep      = false;
   bocHigh = bocLow = chochLevel = tpLevel = 0;
   trackedBocHigh = trackedBocLow = absoluteSlPoint = 0;
   independentBarsAfterBoc = 0;
   independentBarsAllowed  = 1;
   totalBars    = 0;
   lastBarTime  = 0;

   double o0 = iOpen(_Symbol,  PERIOD_CURRENT, 0);
   double c0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   double h0 = iHigh(_Symbol,  PERIOD_CURRENT, 0);
   double l0 = iLow(_Symbol,   PERIOD_CURRENT, 0);

   if(c0 > o0)
   {
      swingBias  = BULLISH;
      lastHigh   = Pivot(h0, false, 0);
      confirmLow = Pivot(l0, true,  0);
   }
   else
   {
      swingBias   = BEARISH;
      lastLow     = Pivot(l0, false, 0);
      confirmHigh = Pivot(h0, true,  0);
   }

   // Print mode info
   if(LotMode == FIXED_LOT)
      Print("SKMS EA started | Mode: Fixed Lot = ", FixedLot);
   else
      Print("SKMS EA started | Mode: Fixed Risk = $", RiskAmount, " per trade");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  ON TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   double O = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double C = iClose(_Symbol, PERIOD_CURRENT, 1);
   double H = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double L = iLow(_Symbol,   PERIOD_CURRENT, 1);

   totalBars++;
   int currentBarIdx = totalBars;
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);

   ProcessIndicatorLogic(O, C, H, L, prevClose, currentBarIdx);
   ProcessStrategyExecution(O, C, H, L);
}

//+------------------------------------------------------------------+
//|  INDICATOR LOGIC                                                |
//+------------------------------------------------------------------+
void ProcessIndicatorLogic(double O, double C, double H, double L,
                            double prevClose, int barIdx)
{
   // Update last high / last low
   if(swingBias == BULLISH)
   {
      if(C > lastHigh.price && !lastHigh.confirmed)
      {
         lastHigh = Pivot(H, false, barIdx);
         double ibLevel = (O != prevClose) ? prevClose : L;
         lastIndBullBar = IndependentBar(ibLevel, barIdx);
         retracementStartLevel = lastIndBullBar.level;
         retracementStarted    = false;
      }
      else if(H > lastHigh.price && C < lastHigh.price && lastHigh.confirmed)
         lastHigh.price = H;
      else if(H > lastHigh.price && C < lastHigh.price && !lastHigh.confirmed)
         lastHigh = Pivot(H, false, barIdx);
   }
   else if(swingBias == BEARISH)
   {
      if(C < lastLow.price && !lastLow.confirmed)
      {
         lastLow = Pivot(L, false, barIdx);
         double ibLevel = (O != prevClose) ? prevClose : H;
         lastIndBearBar = IndependentBar(ibLevel, barIdx);
         retracementStartLevel = lastIndBearBar.level;
         retracementStarted    = false;
      }
      else if(L < lastLow.price && C > lastLow.price && lastLow.confirmed)
         lastLow.price = L;
      else if(L < lastLow.price && C > lastLow.price && !lastLow.confirmed)
         lastLow = Pivot(L, false, barIdx);
   }

   // Update confirm high / confirm low
   if(swingBias == BULLISH)
   {
      if(confirmLow.price > 0 && L < confirmLow.price && C > confirmLow.price && confirmLow.confirmed)
         confirmLow.price = L;
      else if(confirmLow.price > 0 && L < confirmLow.price && C > confirmLow.price && !confirmLow.confirmed)
         confirmLow = Pivot(L, false, barIdx);
   }
   else if(swingBias == BEARISH)
   {
      if(confirmHigh.price > 0 && H > confirmHigh.price && C < confirmHigh.price && confirmHigh.confirmed)
         confirmHigh.price = H;
      else if(confirmHigh.price > 0 && H > confirmHigh.price && C < confirmHigh.price && !confirmHigh.confirmed)
         confirmHigh = Pivot(H, false, barIdx);
   }

   // Retracement start check
   if(!retracementStarted && retracementStartLevel > 0)
   {
      if(swingBias == BULLISH)
      {
         if(C < retracementStartLevel)
         { retracementStarted = true; retracementStartLevel = 0; lastHigh.confirmed = true; }
         else if(L < retracementStartLevel)
            retracementStartLevel = L;
      }
      else if(swingBias == BEARISH)
      {
         if(C > retracementStartLevel)
         { retracementStarted = true; retracementStartLevel = 0; lastLow.confirmed = true; }
         else if(H > retracementStartLevel)
            retracementStartLevel = H;
      }
   }

   // BOS / CHOCH Detection
   if(retracementStarted)
   {
      if(swingBias == BULLISH)
      {
         // BEARISH CHOCH → Buy setup
         if(confirmLow.price > 0 && C < confirmLow.price && confirmLow.confirmed)
         {
            Print("Bearish CHOCH at ", confirmLow.price);
            double hh; int hhBar;
            GetHighestHigh(confirmLow.barIndex, barIdx, hh, hhBar);
            confirmHigh = Pivot(hh, true, hhBar);

            if(!bearishChochActive && !bullishChochActive && !IsTradeOpen())
            {
               // Volume confirmation: confirmLow bar volume < breakout candle volume
               bool volumeOk = true;
               if(UseVolumeConfirmation)
               {
                  int confirmLowBarsAgo = totalBars - confirmLow.barIndex;
                  long confirmLowVol    = (confirmLowBarsAgo >= 0) ? iVolume(_Symbol, PERIOD_CURRENT, confirmLowBarsAgo) : 0;
                  long bocVol           = iVolume(_Symbol, PERIOD_CURRENT, 1);
                  volumeOk = (bocVol > confirmLowVol);
                  if(!volumeOk)
                     Print("Vol FAILED | ConfirmLow vol=", confirmLowVol, " BOC vol=", bocVol);
                  else
                     Print("Vol PASSED | ConfirmLow vol=", confirmLowVol, " BOC vol=", bocVol);
               }
               if(volumeOk)
               {
                  bearishChochActive  = true;
                  chochLevel          = confirmLow.price;
                  tpLevel             = confirmHigh.price;
                  bocHigh             = H; bocLow = L;
                  trackedBocHigh      = H; trackedBocLow = L;
                  absoluteSlPoint     = L;
                  isBocNearToSweep    = CheckIsBocNearToSweep(chochLevel, O, C);
                  independentBarsAfterBoc = 0;
                  if(!ValidateBearishChoch(O, C, H, L, chochLevel))
                  { Print("BOC invalid, resetting"); ResetBuySetup(); }
               }
            }

            swingBias             = BEARISH;
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = lastIndBearBar.level;
         }
         // BULLISH BOS
         else if(lastHigh.price > 0 && C > lastHigh.price && lastHigh.confirmed)
         {
            double ll; int llBar;
            GetLowestLow(lastHigh.barIndex, barIdx, ll, llBar);
            confirmLow            = Pivot(ll, true, llBar);
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = lastIndBullBar.level;
         }
      }
      else if(swingBias == BEARISH)
      {
         // BULLISH CHOCH → Sell setup
         if(confirmHigh.price > 0 && C > confirmHigh.price && confirmHigh.confirmed)
         {
            Print("Bullish CHOCH at ", confirmHigh.price);
            double ll; int llBar;
            GetLowestLow(confirmHigh.barIndex, barIdx, ll, llBar);
            confirmLow = Pivot(ll, true, llBar);

            if(!bullishChochActive && !bearishChochActive && !IsTradeOpen())
            {
               // Volume confirmation: confirmHigh bar volume < breakout candle volume
               bool volumeOk = true;
               if(UseVolumeConfirmation)
               {
                  int confirmHighBarsAgo = totalBars - confirmHigh.barIndex;
                  long confirmHighVol    = (confirmHighBarsAgo >= 0) ? iVolume(_Symbol, PERIOD_CURRENT, confirmHighBarsAgo) : 0;
                  long bocVol           = iVolume(_Symbol, PERIOD_CURRENT, 1);
                  volumeOk = (bocVol > confirmHighVol);
                  if(!volumeOk)
                     Print("Vol FAILED | ConfirmHigh vol=", confirmHighVol, " BOC vol=", bocVol);
                  else
                     Print("Vol PASSED | ConfirmHigh vol=", confirmHighVol, " BOC vol=", bocVol);
               }
               if(volumeOk)
               {
                  bullishChochActive  = true;
                  chochLevel          = confirmHigh.price;
                  tpLevel             = confirmLow.price;
                  bocHigh             = H; bocLow = L;
                  trackedBocHigh      = H; trackedBocLow = L;
                  absoluteSlPoint     = H;
                  isBocNearToSweep    = CheckIsBocNearToSweep(chochLevel, O, C);
                  independentBarsAfterBoc = 0;
                  if(!ValidateBullishChoch(O, C, H, L, chochLevel))
                  { Print("BOC invalid, resetting"); ResetSellSetup(); }
               }
            }

            swingBias             = BULLISH;
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = lastIndBullBar.level;
         }
         // BEARISH BOS
         else if(lastLow.price > 0 && C < lastLow.price && lastLow.confirmed)
         {
            double hh; int hhBar;
            GetHighestHigh(lastLow.barIndex, barIdx, hh, hhBar);
            confirmHigh           = Pivot(hh, true, hhBar);
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = lastIndBearBar.level;
         }
      }
   }
   else
   {
      if(swingBias == BULLISH && confirmLow.price > 0 && C < confirmLow.price)
      {
         swingBias = BEARISH;
         confirmHigh = lastHigh; confirmHigh.confirmed = true;
         lastLow = confirmLow;
         confirmLow = Pivot(0,false,0); lastHigh = Pivot(0,false,0);
         lastIndBullBar = IndependentBar(L, barIdx);
         retracementStartLevel = lastIndBullBar.level;
         retracementStarted = false;
      }
      else if(swingBias == BEARISH && confirmHigh.price > 0 && C > confirmHigh.price)
      {
         swingBias = BULLISH;
         confirmLow = lastLow; confirmLow.confirmed = true;
         lastHigh = confirmHigh;
         confirmHigh = Pivot(0,false,0); lastLow = Pivot(0,false,0);
         lastIndBearBar = IndependentBar(H, barIdx);
         retracementStartLevel = lastIndBearBar.level;
         retracementStarted = false;
      }
   }
}

//+------------------------------------------------------------------+
//|  STRATEGY EXECUTION                                             |
//+------------------------------------------------------------------+
void ProcessStrategyExecution(double O, double C, double H, double L)
{
   bool isBullishCandle = C > O;
   bool isBearishCandle = C < O;

   //=================================================================
   // BUY SETUP
   //=================================================================
   if(bearishChochActive && !IsTradeOpen())
   {
      if(C < trackedBocLow && O > trackedBocLow)
      {
         independentBarsAfterBoc++;
         int maxAllowed = isBocNearToSweep ? independentBarsAllowed + 1 : independentBarsAllowed;

         if(independentBarsAfterBoc > maxAllowed
            || (!isBocNearToSweep && !CheckIsValidNextIBAfterBoc(trackedBocLow, O, C) && independentBarsAfterBoc == 1)
            || CheckIsMomentumCandle(H, L, O, C))
         {
            Print("Buy setup cancelled");
            ResetBuySetup();
         }
         else
         {
            trackedBocLow   = L;
            absoluteSlPoint = L;
            if(isBocNearToSweep && independentBarsAfterBoc == 1)
               trackedBocHigh = H;
         }
      }
      else
      {
         if(L < trackedBocLow && C > trackedBocLow)
         { trackedBocLow = L; absoluteSlPoint = L; }

         if(C > trackedBocHigh && H > trackedBocHigh)
         {
            if(CheckIsMomentumCandle(H, L, O, C, 0.3)
               && CheckIsSignificantBreakout(trackedBocHigh, H, L, O, C)
               && isBullishCandle)
            {
               double sl      = absoluteSlPoint - SL_Buffer;
               double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double lotSize  = CalculateLotSize(askPrice, sl);

               Print("BUY | Lot=", lotSize, " Entry~", askPrice, " SL=", sl, " TP=", tpLevel);
               if(trade.Buy(lotSize, _Symbol, 0, sl, tpLevel, "BUY @ CHOCH"))
                  Print("Buy placed OK");
               else
                  Print("Buy failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
               ResetBuySetup();
            }
            else
               trackedBocHigh = H;
         }
         else if(H > trackedBocHigh && C < trackedBocHigh)
            trackedBocHigh = H;
      }
   }

   //=================================================================
   // SELL SETUP
   //=================================================================
   if(bullishChochActive && !IsTradeOpen())
   {
      if(C > trackedBocHigh && O < trackedBocHigh)
      {
         independentBarsAfterBoc++;
         int maxAllowed = isBocNearToSweep ? independentBarsAllowed + 1 : independentBarsAllowed;

         if(independentBarsAfterBoc > maxAllowed
            || (!isBocNearToSweep && !CheckIsValidNextIBAfterBoc(chochLevel, O, C) && independentBarsAfterBoc == 0)
            || CheckIsMomentumCandle(H, L, O, C, 0.2))
         {
            Print("Sell setup cancelled");
            ResetSellSetup();
         }
         else
         {
            trackedBocHigh  = H;
            absoluteSlPoint = H;
            if(isBocNearToSweep && independentBarsAfterBoc == 1)
               trackedBocHigh = H;
         }
      }
      else
      {
         if(H > trackedBocHigh && C < trackedBocHigh)
         { trackedBocHigh = H; absoluteSlPoint = H; }

         if(C < trackedBocLow && L < trackedBocLow)
         {
            if(CheckIsMomentumCandle(H, L, O, C, 0.38)
               && CheckIsSignificantBreakout(trackedBocLow, H, L, O, C)
               && isBearishCandle)
            {
               double sl      = absoluteSlPoint + SL_Buffer;
               double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double lotSize  = CalculateLotSize(bidPrice, sl);

               Print("SELL | Lot=", lotSize, " Entry~", bidPrice, " SL=", sl, " TP=", tpLevel);
               if(trade.Sell(lotSize, _Symbol, 0, sl, tpLevel, "SELL @ CHOCH"))
                  Print("Sell placed OK");
               else
                  Print("Sell failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
               ResetSellSetup();
            }
            else
               trackedBocLow = L;
         }
         else if(L < trackedBocLow && C > trackedBocLow)
            trackedBocLow = L;
      }
   }
}

//+------------------------------------------------------------------+
//|  DEINIT                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("SKMS EA removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
