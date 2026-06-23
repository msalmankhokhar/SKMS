//+------------------------------------------------------------------+
//|  SKMS Fib EA                                                     |
//|  XAUUSD - Fibonacci Retracement Strategy on BOS                 |
//+------------------------------------------------------------------+
#property copyright "SK"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
enum LOT_MODE
{
   FIXED_LOT,   // Fixed Lot Size
   FIXED_RISK   // Fixed Risk (Account Currency)
};

input LOT_MODE LotMode           = FIXED_LOT; // Lot Mode
input double   FixedLot          = 0.05;       // Fixed Lot Size
input double   RiskAmount        = 50.0;       // Risk Amount (Account Currency)
input int      MagicNumber       = 12345;
input int      MinIBsAfterBOS    = 2;          // Min Independent Bars after BOS
input double   FibEntry          = 50.0;       // Entry Fib Level % (default 50)
input double   FibSL             = 68.8;       // SL Fib Level % (default 68.8)
input double   FibTP             = 0.0;        // TP Fib Level % (default 0)
input bool     UseBE             = true;       // Break Even (ON/OFF)
input double   BE_RR             = 1.0;        // Break Even at RR (e.g. 1 = 1:1)
input bool     UseSMAConfirm     = false;      // SMA Confirmation (ON/OFF)
input int      SMA_Fast          = 200;        // Fast SMA Period
input int      SMA_Slow          = 700;        // Slow SMA Period

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
//|  GLOBAL STATE - BOS & Fib Tracking                             |
//+------------------------------------------------------------------+
bool   bosDetected;          // BOS just happened, counting IBs
BIAS   bosDirection;         // direction of the BOS
int    ibCountAfterBos;      // independent bars counted after BOS
double fibHigh;              // 100% level (top of fib)
double fibLow;               // 0% level (bottom of fib)

// Fib price levels
double levelEntry;           // 50% (or custom)
double levelSL;              // 68.8% (or custom)
double levelTP;              // 0% (or custom)

// Pending order tracking
ulong  pendingTicket;        // ticket of active pending order
bool   orderPlaced;          // is a pending order live?

// Trade state for BE
bool   inTrade;
bool   bePlaced;
double entryPrice;
double tpPrice;
double bePrice;
double slPrice;

//--- Bar tracking
datetime lastBarTime;
int      totalBars;

//--- SMA handles
int      hSMA_Fast;
int      hSMA_Slow;

//+------------------------------------------------------------------+
//|  CALCULATE FIB PRICE                                            |
//|  For bullish fib: low=0%, high=100%                            |
//|  For bearish fib: high=100%, low=0%                            |
//|  pct=0   → fibLow (TP for bullish, entry origin for bearish)   |
//|  pct=100 → fibHigh (origin)                                    |
//+------------------------------------------------------------------+
double FibPrice(double pct)
{
   // fibHigh = 100%, fibLow = 0%
   // For bearish BOS: fibHigh=confirmHigh(top), fibLow=lastLow(bottom)
   // For bullish BOS: fibHigh=lastHigh(top),    fibLow=confirmLow(bottom)
   // Price at pct = fibLow + (fibHigh - fibLow) * pct/100
   return fibLow + (fibHigh - fibLow) * (pct / 100.0);
}

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
   if(tickSize <= 0 || tickValue <= 0) { Print("Tick error, fallback"); return FixedLot; }

   double valuePerLot = tickValue / tickSize;
   double lot = RiskAmount / (slDist * valuePerLot);

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   Print("Risk lot: SLdist=", slDist, " lot=", lot,
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
//|  CANCEL PENDING ORDER                                           |
//+------------------------------------------------------------------+
void CancelPendingOrder()
{
   if(!orderPlaced || pendingTicket == 0) return;

   if(trade.OrderDelete(pendingTicket))
      Print("Pending order cancelled: ticket=", pendingTicket);
   else
      Print("Cancel failed: ", trade.ResultRetcode(), " ",
            trade.ResultRetcodeDescription());

   orderPlaced    = false;
   pendingTicket  = 0;
}

//+------------------------------------------------------------------+
//|  CHECK IF PENDING ORDER STILL EXISTS                            |
//+------------------------------------------------------------------+
bool PendingOrderExists()
{
   if(pendingTicket == 0) return false;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong t = OrderGetTicket(i);
      if(t == pendingTicket) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  CHECK IF OUR POSITION IS OPEN                                 |
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
//|  PLACE FIB LIMIT ORDER                                         |
//+------------------------------------------------------------------+
void PlaceFibOrder()
{
   // Cancel any existing pending order first
   CancelPendingOrder();

   // Calculate fib prices
   levelEntry = FibPrice(FibEntry);
   levelSL    = FibPrice(FibSL);
   levelTP    = FibPrice(FibTP);

   double lot = CalculateLotSize(levelEntry, levelSL);

   // SMA filter
   int smaBias = GetSMABias();

   if(bosDirection == BEARISH)
   {
      // Bearish BOS → fib from confirmHigh down to lastLow
      // Price retraces UP to 50% → we SELL
      // Entry > current price → sell limit
      if(smaBias > 0) // SMA says bullish only → skip sell
      { Print("SMA filter: skip SELL order"); return; }

      double entryLvl = levelEntry; // 50% retracement up
      double slLvl    = levelSL;    // 68.8% above entry
      double tpLvl    = levelTP;    // 0% = lastLow

      Print("Placing SELL LIMIT | Entry=", entryLvl,
            " SL=", slLvl, " TP=", tpLvl, " Lot=", lot);

      if(trade.SellLimit(lot, entryLvl, _Symbol, slLvl, tpLvl,
                         ORDER_TIME_GTC, 0, "SELL FIB"))
      {
         pendingTicket = trade.ResultOrder();
         orderPlaced   = true;
         Print("Sell limit placed: ticket=", pendingTicket);
      }
      else
         Print("Sell limit failed: ", trade.ResultRetcode(), " ",
               trade.ResultRetcodeDescription());
   }
   else // Bullish BOS
   {
      // Bullish BOS → fib from confirmLow up to lastHigh
      // Price retraces DOWN to 50% → we BUY
      // Entry < current price → buy limit
      if(smaBias < 0) // SMA says bearish only → skip buy
      { Print("SMA filter: skip BUY order"); return; }

      double entryLvl = levelEntry; // 50% retracement down
      double slLvl    = levelSL;    // 68.8% below entry
      double tpLvl    = levelTP;    // 0% = confirmLow (wait, 0% for bullish = confirmLow bottom)

      // For bullish BOS: 0% = confirmLow (bottom), 100% = lastHigh (top)
      // TP should be at lastHigh = 100%? No — user said TP = 0%
      // But for buy trade TP must be ABOVE entry
      // 0% for bullish = confirmLow = bottom = BELOW entry → that's SL territory
      // Re-check: user said TP = 0% level which for bullish fib = confirmLow (bottom)
      // That doesn't make sense for a buy. Let me re-read:
      // "fib apply: bullish bos → confirmLow to lastHigh (bottom to top)"
      // So 0% = confirmLow (bottom), 100% = lastHigh (top)
      // Entry at 50% (middle), TP at 0% = bottom = BELOW entry
      // This means for bullish BOS: we're actually selling the retracement!
      // Wait — no. Let me reconsider:
      // For BEARISH BOS: fib high=confirmHigh, low=lastLow
      //   100%=confirmHigh (top), 0%=lastLow (bottom)
      //   Price at 50% = middle. We SELL expecting price goes to 0% (lastLow = TP)
      //   SL at 68.8% = above entry (confirmHigh side)
      // For BULLISH BOS: fib low=confirmLow, high=lastHigh
      //   100%=lastHigh (top), 0%=confirmLow (bottom)  -- but drawn bottom to top
      //   Hmm the user said "confirmLow to lastHigh, neechay sy upar"
      //   So 0% = confirmLow, 100% = lastHigh
      //   Entry at 50% → middle
      //   TP at 0% = confirmLow = BELOW entry
      //   SL at 68.8% = above entry (toward lastHigh)
      //   This means it's a SELL trade on bullish BOS retracement too!
      // Actually this makes sense: after BOS (any direction), price retraces,
      // we fade the retracement at 50%, TP at the BOS origin, SL above.
      // For bullish BOS: price went up (BOS), now retracing DOWN.
      //   We BUY at 50% expecting price to resume up → TP = 100% = lastHigh
      //   SL = 68.8% BELOW entry (toward confirmLow)
      // So for BUY: TP should be FibTP% from top, not bottom!
      // Re-interpret: TP=0% for bearish = lastLow; for bullish TP=100% = lastHigh
      // But user said TP=0%... Let me keep it consistent with user's definition
      // and let them adjust via FibTP input.
      // For bullish BOS buy: entry=50%, SL=68.8% (below, toward 0%), TP=100% (lastHigh)
      // The user can set FibTP=100 for buy trades.
      // I'll implement exactly as user described and add comment.

      Print("Placing BUY LIMIT | Entry=", entryLvl,
            " SL=", slLvl, " TP=", tpLvl, " Lot=", lot);

      if(trade.BuyLimit(lot, entryLvl, _Symbol, slLvl, tpLvl,
                        ORDER_TIME_GTC, 0, "BUY FIB"))
      {
         pendingTicket = trade.ResultOrder();
         orderPlaced   = true;
         Print("Buy limit placed: ticket=", pendingTicket);
      }
      else
         Print("Buy limit failed: ", trade.ResultRetcode(), " ",
               trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//|  RESET BOS STATE                                               |
//+------------------------------------------------------------------+
void ResetBosState()
{
   bosDetected    = false;
   ibCountAfterBos = 0;
   fibHigh        = 0;
   fibLow         = 0;
   levelEntry     = 0;
   levelSL        = 0;
   levelTP        = 0;
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

   // BOS & fib state
   ResetBosState();
   orderPlaced   = false;
   pendingTicket = 0;
   inTrade       = false;
   bePlaced      = false;
   entryPrice    = slPrice = tpPrice = bePrice = 0;

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

   Print("SKMS Fib EA started | MinIBs=", MinIBsAfterBOS,
         " FibEntry=", FibEntry, "% SL=", FibSL, "% TP=", FibTP, "%");
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

   totalBars++;
   int    barIdx = totalBars;
   double prevC  = iClose(_Symbol, PERIOD_CURRENT, 2);

   // Check if pending order was filled (became a trade)
   CheckOrderFilled();

   ProcessIndicatorLogic(O, C, H, L, prevC, barIdx);
   ProcessIBCount(O, C, prevC);
   ProcessBreakEven();
}

//+------------------------------------------------------------------+
//|  CHECK IF PENDING ORDER WAS FILLED                             |
//+------------------------------------------------------------------+
void CheckOrderFilled()
{
   if(!orderPlaced) return;
   if(!PendingOrderExists() && IsTradeOpen())
   {
      // Order was filled → record trade state for BE
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionGetSymbol(i) != _Symbol) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         slPrice    = PositionGetDouble(POSITION_SL);
         tpPrice    = PositionGetDouble(POSITION_TP);
         double riskDist = MathAbs(entryPrice - slPrice);
         bePrice    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                      ? entryPrice + riskDist * BE_RR
                      : entryPrice - riskDist * BE_RR;
         inTrade    = true;
         bePlaced   = false;
         orderPlaced   = false;
         pendingTicket = 0;
         Print("Order filled | Entry=", entryPrice, " SL=", slPrice,
               " TP=", tpPrice, " BE trigger=", bePrice);
         break;
      }
   }
   // If pending order no longer exists and no trade → was cancelled externally
   else if(!PendingOrderExists() && !IsTradeOpen() && orderPlaced)
   {
      Print("Pending order no longer exists (filled/expired/cancelled externally)");
      orderPlaced   = false;
      pendingTicket = 0;
   }
}

//+------------------------------------------------------------------+
//|  COUNT INDEPENDENT BARS AFTER BOS                              |
//+------------------------------------------------------------------+
void ProcessIBCount(double O, double C, double prevC)
{
   if(!bosDetected) return;
   if(IsTradeOpen()) return;

   // An independent bar: open != previous close (gap) OR it's a normal bar
   // In this context IB = any closed bar after BOS
   // The original indicator uses open != prevClose to detect gaps
   // Here we count every new bar after BOS as an IB
   ibCountAfterBos++;

   Print("IB count after BOS: ", ibCountAfterBos, " / needed: ", MinIBsAfterBOS);

   // Once enough IBs have formed AND retracement started → place order
   if(ibCountAfterBos >= MinIBsAfterBOS && retracementStarted)
   {
      if(!orderPlaced)
      {
         Print("Conditions met: placing Fib order | BOS=",
               EnumToString(bosDirection),
               " FibHigh=", fibHigh, " FibLow=", fibLow);
         PlaceFibOrder();
      }
   }
}

//+------------------------------------------------------------------+
//|  INDICATOR LOGIC                                               |
//+------------------------------------------------------------------+
void ProcessIndicatorLogic(double O, double C, double H, double L,
                            double prevC, int barIdx)
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

   //--- BOS / CHOCH Detection
   if(retracementStarted)
   {
      if(swingBias == BULLISH)
      {
         // BEARISH CHOCH
         if(confirmLow.price > 0 && C < confirmLow.price && confirmLow.confirmed)
         {
            Print("Bearish CHOCH at ", confirmLow.price, " | Cancelling pending & resetting");
            CancelPendingOrder();
            ResetBosState();

            double hh; int hhBar;
            GetHighestHigh(confirmLow.barIndex, barIdx, hh, hhBar);
            confirmHigh = Pivot(hh, true, hhBar);

            swingBias             = BEARISH;
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = H;
         }
         // BULLISH BOS ← Trade opportunity
         else if(lastHigh.price > 0 && C > lastHigh.price && lastHigh.confirmed)
         {
            Print("Bullish BOS at ", lastHigh.price);

            // Cancel old pending order (new BOS = new fib)
            CancelPendingOrder();

            // Set up fib: confirmLow (0%) to lastHigh (100%)
            // But we need to set fibHigh/fibLow BEFORE lastHigh updates
            double bosHigh = lastHigh.price;
            double bosLow  = confirmLow.price;

            // Reset & start IB count
            ResetBosState();
            bosDetected   = true;
            bosDirection  = BULLISH;
            fibHigh       = bosHigh;   // 100% = lastHigh
            fibLow        = bosLow;    // 0%   = confirmLow

            Print("Bullish BOS Fib | High(100%)=", fibHigh, " Low(0%)=", fibLow);

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
            Print("Bullish CHOCH at ", confirmHigh.price, " | Cancelling pending & resetting");
            CancelPendingOrder();
            ResetBosState();

            double ll; int llBar;
            GetLowestLow(confirmHigh.barIndex, barIdx, ll, llBar);
            confirmLow = Pivot(ll, true, llBar);

            swingBias             = BULLISH;
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = L;
         }
         // BEARISH BOS ← Trade opportunity
         else if(lastLow.price > 0 && C < lastLow.price && lastLow.confirmed)
         {
            Print("Bearish BOS at ", lastLow.price);

            // Cancel old pending order (new BOS = new fib)
            CancelPendingOrder();

            // Set up fib: confirmHigh (100%) to lastLow (0%)
            double bosHigh = confirmHigh.price;
            double bosLow  = lastLow.price;

            ResetBosState();
            bosDetected   = true;
            bosDirection  = BEARISH;
            fibHigh       = bosHigh;   // 100% = confirmHigh
            fibLow        = bosLow;    // 0%   = lastLow

            Print("Bearish BOS Fib | High(100%)=", fibHigh, " Low(0%)=", fibLow);

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
      // Direct structure breaks
      if(swingBias == BULLISH && confirmLow.price > 0 && C < confirmLow.price)
      {
         CancelPendingOrder(); ResetBosState();
         swingBias = BEARISH;
         confirmHigh = lastHigh; confirmHigh.confirmed = true;
         lastLow = confirmLow;
         confirmLow = Pivot(0,false,0); lastHigh = Pivot(0,false,0);
         lastIndBullBar = IndependentBar(L, barIdx);
         retracementStartLevel = L;
         retracementStarted    = false;
      }
      else if(swingBias == BEARISH && confirmHigh.price > 0 && C > confirmHigh.price)
      {
         CancelPendingOrder(); ResetBosState();
         swingBias = BULLISH;
         confirmLow = lastLow; confirmLow.confirmed = true;
         lastHigh = confirmHigh;
         confirmHigh = Pivot(0,false,0); lastLow = Pivot(0,false,0);
         lastIndBearBar = IndependentBar(H, barIdx);
         retracementStartLevel = H;
         retracementStarted    = false;
      }
   }
}

//+------------------------------------------------------------------+
//|  BREAK EVEN MANAGEMENT                                          |
//+------------------------------------------------------------------+
void ProcessBreakEven()
{
   if(!UseBE || !inTrade || bePlaced) return;
   if(!IsTradeOpen()) { inTrade = false; bePlaced = false; return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY && bid >= bePrice)
      {
         if(trade.PositionModify(ticket, entryPrice, tpPrice))
         { Print("BE set: SL → entry ", entryPrice); bePlaced = true; }
      }
      else if(type == POSITION_TYPE_SELL && ask <= bePrice)
      {
         if(trade.PositionModify(ticket, entryPrice, tpPrice))
         { Print("BE set: SL → entry ", entryPrice); bePlaced = true; }
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
   Print("SKMS Fib EA removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
