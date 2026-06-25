//+------------------------------------------------------------------+
//|               Mustafa_FX_retest_strategy.mq5                     |
//+------------------------------------------------------------------+
//| CHANGELOG                                                        |
//|  v4.00  Original bias-aligned EMA breakout-retest.               |
//|  v4.01  Hardening: ceiling setup count, lot/price normalization, |
//|         order-side validation, partial-fill rollback, copy       |
//|         guards, expiration fallback, bias-flip cancel.           |
//|  v4.02  SMC STRUCTURE MODULE (toggleable):                       |
//|           - Displacement filter (FVG-creating impulse).          |
//|           - Entry anchor selectable: Legacy EMA / FVG-fill / OTE. |
//|         Legacy behaviour is fully preserved via EntryMode.       |
//+------------------------------------------------------------------+
#property copyright "Mustafa_FX"
#property link      ""
#property version   "4.02"
#property description "Mustafa_FX Retest Strategy - Bias Aligned + SMC structure module"

#include <Trade\Trade.mqh>

//--- Entry-mode selector (SMC structure module) -------------------
enum ENUM_ENTRY_MODE
{
   ENTRY_LEGACY_EMA = 0,   // Legacy: 21EMA -/+ EntryDepth*ATR (v4.00 behaviour)
   ENTRY_FVG_FILL   = 1,   // Enter at 50% fill of the breakout FVG
   ENTRY_OTE_BAND   = 2    // Enter inside the OTE retracement band
};

//--- Main Trade Inputs
input double          RiskPercent           = 1.0;       // Total Risk per trade (%)
input double          TP1_RewardRatio       = 1.0;       // Position 1 TP (R-Multiple)
input double          TP2_RewardRatio       = 1.5;       // Position 2 TP (R-Multiple)
input double          BE_Activation_Percent = 50.0;      // Move SL to Entry when price reaches this % of TP1
input ulong           BaseMagicNumber       = 123456;    // Base Magic Number
input int             MaxSetupsPerTimeframe = 1;         // Max concurrent setups PER timeframe
input bool            CancelOnBiasFlip      = true;      // Cancel pending orders if Master Bias flips

//--- SMC Structure Module (v4.02) ---------------------------------
input ENUM_ENTRY_MODE EntryMode             = ENTRY_FVG_FILL; // Entry anchor
input bool            RequireDisplacement   = true;      // Require FVG-creating displacement on the break
input double          DisplacementBodyAtr   = 1.0;       // Min displacement candle body / ATR
input double          OteLevel              = 0.705;     // OTE retrace level (0.62-0.79 band, 0.705 = sweet spot)

//--- Master Bias & Trend Inputs
input int             BiasEmaLen            = 200;       // Master Trend Bias EMA
input int             FastEmaLen            = 34;        // Fast Trend EMA
input int             SlowEmaLen            = 144;       // Slow Trend EMA
input int             PullEmaLen            = 21;        // Pullback Target EMA (Legacy mode)

//--- Breakout & Execution Inputs
input int             AtrLen                = 14;        // ATR Length
input int             BreakLookback         = 20;        // Breakout Swing Lookback
input double          MinBreakBodyAtr       = 0.20;      // Min Breakout Body / ATR
input double          EntryDepthAtr         = 0.40;      // Entry Depth into pullback (ATR, Legacy mode)
input double          SlBufferAtr           = 0.30;      // Stop Loss buffer beyond structure (ATR)
input int             MaxHuntBars           = 40;        // Max bars before limit order expires

//--- Global Objects & Handles
CTrade         trade;
datetime       lastBarTime;
int            biasEmaHandle, fastEmaHandle, slowEmaHandle, pullEmaHandle, atrHandle;

//--- Timeframe-Aware Magic Numbers
ulong          Magic_TP1, Magic_TP2;

//--- Cached symbol constraints (refreshed each new bar)
double         g_volStep, g_minVol, g_maxVol, g_tickSize, g_stopsLevel;

//--- Structs ------------------------------------------------------
struct FvgInfo
{
   bool   exists;
   bool   bodyStrong;
   double top;
   double bottom;
   double mid;
};

struct EntryPlan
{
   bool   valid;
   double limitPrice;
   double slPrice;
   string reason;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Magic_TP1 = BaseMagicNumber + PeriodSeconds(_Period);
    Magic_TP2 = Magic_TP1 + 1;

    biasEmaHandle = iMA(_Symbol, _Period, BiasEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    fastEmaHandle = iMA(_Symbol, _Period, FastEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    slowEmaHandle = iMA(_Symbol, _Period, SlowEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    pullEmaHandle = iMA(_Symbol, _Period, PullEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    atrHandle     = iATR(_Symbol, _Period, AtrLen);

    if(biasEmaHandle == INVALID_HANDLE || fastEmaHandle == INVALID_HANDLE ||
       slowEmaHandle == INVALID_HANDLE || pullEmaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
    {
        Print("Error initializing indicator handles!");
        return(INIT_FAILED);
    }

    if(EntryMode == ENTRY_OTE_BAND && (OteLevel < 0.5 || OteLevel > 0.9))
        Print("Warning: OteLevel ", OteLevel, " is outside the typical 0.62-0.79 OTE band.");

    Print("Mustafa_FX_retest_strategy v4.02 Initialized. EntryMode=", EnumToString(EntryMode),
          " RequireDisplacement=", RequireDisplacement);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(biasEmaHandle);
    IndicatorRelease(fastEmaHandle);
    IndicatorRelease(slowEmaHandle);
    IndicatorRelease(pullEmaHandle);
    IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Helpers: price / volume normalization                            |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickSize <= 0) return NormalizeDouble(price, _Digits);
    return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

double NormalizeVolumeDown(double vol)
{
    double step = g_volStep;
    if(step <= 0) step = g_minVol;
    if(step <= 0) return 0;
    vol = MathFloor(vol / step) * step;
    if(g_maxVol > 0 && vol > g_maxVol) vol = g_maxVol;
    return vol;
}

void RefreshSymbolConstraints()
{
    g_volStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    g_minVol     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxVol     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    g_stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
}

//+------------------------------------------------------------------+
//| Resolve a broker-supported pending-order expiration mode         |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_TIME ResolveExpiration(datetime &expiration)
{
    long expMode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
    if((expMode & SYMBOL_EXPIRATION_SPECIFIED) != 0)
    {
        expiration = TimeCurrent() + (MaxHuntBars * PeriodSeconds(_Period));
        return ORDER_TIME_SPECIFIED;
    }
    expiration = 0;
    return ORDER_TIME_GTC;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double slPrice)
{
    double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double slDistance = MathAbs(entryPrice - slPrice);

    if(slDistance <= 0 || tickSize <= 0 || tickValue <= 0) return 0;
    double lossInTicks = slDistance / tickSize;
    if(lossInTicks <= 0) return 0;
    return riskAmount / (lossInTicks * tickValue);
}

//+------------------------------------------------------------------+
//| Count active setups for this timeframe (ceiling, not floor)      |
//+------------------------------------------------------------------+
int CountActiveSetups()
{
    int legs = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            ulong m = PositionGetInteger(POSITION_MAGIC);
            if(m == Magic_TP1 || m == Magic_TP2) legs++;
        }
    }
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(OrderGetTicket(i) == 0) continue;
        if(OrderGetString(ORDER_SYMBOL) == _Symbol)
        {
            ulong m = OrderGetInteger(ORDER_MAGIC);
            if(m == Magic_TP1 || m == Magic_TP2) legs++;
        }
    }
    return (legs + 1) / 2;
}

//+------------------------------------------------------------------+
//| Cancel stale pending orders when Master Bias flips               |
//+------------------------------------------------------------------+
void ManagePendingOrders(bool bullBias, bool bearBias)
{
    if(!CancelOnBiasFlip) return;
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket == 0) continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        ulong m = OrderGetInteger(ORDER_MAGIC);
        if(m != Magic_TP1 && m != Magic_TP2) continue;

        long type = OrderGetInteger(ORDER_TYPE);
        bool isBuyPending  = (type == ORDER_TYPE_BUY_LIMIT  || type == ORDER_TYPE_BUY_STOP);
        bool isSellPending = (type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP);

        if((isBuyPending && bearBias) || (isSellPending && bullBias))
        {
            if(!trade.OrderDelete(ticket))
                PrintFormat("Failed to cancel stale pending #%I64u, retcode=%u", ticket, trade.ResultRetcode());
        }
    }
}

//+------------------------------------------------------------------+
//| Manage Break-Even Logic (Runs every tick)                        |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
    double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        ulong m = PositionGetInteger(POSITION_MAGIC);

        if(PositionGetString(POSITION_SYMBOL) == _Symbol && (m == Magic_TP1 || m == Magic_TP2))
        {
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl    = PositionGetDouble(POSITION_SL);
            double tp    = PositionGetDouble(POSITION_TP);
            long   type  = PositionGetInteger(POSITION_TYPE);

            if(tp == 0) continue;
            double fullTpDistance = MathAbs(tp - entry);
            if(fullTpDistance == 0) continue;

            double targetDistance = fullTpDistance;
            if(m == Magic_TP2 && TP2_RewardRatio > 0)
                targetDistance = (fullTpDistance / TP2_RewardRatio) * TP1_RewardRatio;

            double activationDist = targetDistance * (BE_Activation_Percent / 100.0);

            if(type == POSITION_TYPE_BUY)
            {
                double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(currentBid >= (entry + activationDist) && sl < entry)
                    if(entry - currentBid < -minStopLevel)
                        if(!trade.PositionModify(ticket, NormalizePrice(entry), tp))
                            PrintFormat("BE modify failed #%I64u, retcode=%u", ticket, trade.ResultRetcode());
            }
            else if(type == POSITION_TYPE_SELL)
            {
                double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if(currentAsk <= (entry - activationDist) && (sl > entry || sl == 0))
                    if(currentAsk - entry < -minStopLevel)
                        if(!trade.PositionModify(ticket, NormalizePrice(entry), tp))
                            PrintFormat("BE modify failed #%I64u, retcode=%u", ticket, trade.ResultRetcode());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| FVG detection (3-bar gap on bars 0,1,2; idx0 = last closed bar)  |
//+------------------------------------------------------------------+
FvgInfo DetectBullFVG(const double &high[], const double &low[],
                      const double &close[], const double &open[], double atr)
{
    FvgInfo f; f.exists=false; f.bodyStrong=false; f.top=0; f.bottom=0; f.mid=0;
    // Bullish FVG: gap between candle-1 high (idx2) and candle-3 low (idx0)
    if(low[0] > high[2])
    {
        f.exists  = true;
        f.bottom  = high[2];
        f.top     = low[0];
        f.mid     = (f.top + f.bottom) / 2.0;
        double midBody = close[1] - open[1];                 // displacement candle (idx1)
        f.bodyStrong = (close[1] > open[1]) && (midBody >= DisplacementBodyAtr * atr);
    }
    return f;
}

FvgInfo DetectBearFVG(const double &high[], const double &low[],
                      const double &close[], const double &open[], double atr)
{
    FvgInfo f; f.exists=false; f.bodyStrong=false; f.top=0; f.bottom=0; f.mid=0;
    // Bearish FVG: gap between candle-3 high (idx0) and candle-1 low (idx2)
    if(high[0] < low[2])
    {
        f.exists  = true;
        f.top     = low[2];
        f.bottom  = high[0];
        f.mid     = (f.top + f.bottom) / 2.0;
        double midBody = open[1] - close[1];                 // displacement candle (idx1)
        f.bodyStrong = (close[1] < open[1]) && (midBody >= DisplacementBodyAtr * atr);
    }
    return f;
}

//+------------------------------------------------------------------+
//| Build entry plan (limit + SL) according to EntryMode             |
//+------------------------------------------------------------------+
EntryPlan BuildBullEntry(double atr, double loBefore,
                         const double &high[], const double &low[],
                         const double &pEma[], const FvgInfo &fvg)
{
    EntryPlan p; p.valid=false; p.limitPrice=0; p.slPrice=0; p.reason="";
    double buffer = SlBufferAtr * atr;

    if(EntryMode == ENTRY_LEGACY_EMA)
    {
        p.limitPrice = pEma[0] - (EntryDepthAtr * atr);
        p.slPrice    = loBefore - buffer;
        p.valid = true;
        return p;
    }
    if(EntryMode == ENTRY_FVG_FILL)
    {
        if(!fvg.exists) { p.reason = "Skip BUY: no bullish FVG to fill."; return p; }
        double impulseLow = MathMin(low[0], MathMin(low[1], low[2]));
        p.limitPrice = fvg.mid;                              // 50% fill of the gap
        p.slPrice    = impulseLow - buffer;                  // below the impulse
        p.valid = true;
        return p;
    }
    if(EntryMode == ENTRY_OTE_BAND)
    {
        double impulseHigh = MathMax(high[0], MathMax(high[1], high[2]));
        double origin = loBefore;                            // 0% of the leg
        if(impulseHigh <= origin) { p.reason = "Skip BUY: invalid OTE leg."; return p; }
        p.limitPrice = impulseHigh - OteLevel * (impulseHigh - origin);
        p.slPrice    = origin - buffer;                      // invalidation below leg origin
        p.valid = true;
        return p;
    }
    return p;
}

EntryPlan BuildBearEntry(double atr, double hiBefore,
                         const double &high[], const double &low[],
                         const double &pEma[], const FvgInfo &fvg)
{
    EntryPlan p; p.valid=false; p.limitPrice=0; p.slPrice=0; p.reason="";
    double buffer = SlBufferAtr * atr;

    if(EntryMode == ENTRY_LEGACY_EMA)
    {
        p.limitPrice = pEma[0] + (EntryDepthAtr * atr);
        p.slPrice    = hiBefore + buffer;
        p.valid = true;
        return p;
    }
    if(EntryMode == ENTRY_FVG_FILL)
    {
        if(!fvg.exists) { p.reason = "Skip SELL: no bearish FVG to fill."; return p; }
        double impulseHigh = MathMax(high[0], MathMax(high[1], high[2]));
        p.limitPrice = fvg.mid;
        p.slPrice    = impulseHigh + buffer;
        p.valid = true;
        return p;
    }
    if(EntryMode == ENTRY_OTE_BAND)
    {
        double impulseLow = MathMin(low[0], MathMin(low[1], low[2]));
        double origin = hiBefore;                            // 0% of the leg
        if(origin <= impulseLow) { p.reason = "Skip SELL: invalid OTE leg."; return p; }
        p.limitPrice = impulseLow + OteLevel * (origin - impulseLow);
        p.slPrice    = origin + buffer;
        p.valid = true;
        return p;
    }
    return p;
}

//+------------------------------------------------------------------+
//| Setup validation against broker constraints                      |
//+------------------------------------------------------------------+
bool ValidateBuySetup(double limitPrice, double slPrice, double tp1, double tp2)
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if(slPrice >= limitPrice) { Print("Skip BUY: SL not below entry."); return false; }
    if(tp1 <= limitPrice || tp2 <= limitPrice) { Print("Skip BUY: TP not above entry."); return false; }
    if(limitPrice >= ask - g_stopsLevel) { Print("Skip BUY: limit too close to / above market."); return false; }
    if((limitPrice - slPrice) < g_stopsLevel) { Print("Skip BUY: SL inside stops level."); return false; }
    if((tp1 - limitPrice) < g_stopsLevel) { Print("Skip BUY: TP1 inside stops level."); return false; }
    return true;
}

bool ValidateSellSetup(double limitPrice, double slPrice, double tp1, double tp2)
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(slPrice <= limitPrice) { Print("Skip SELL: SL not above entry."); return false; }
    if(tp1 >= limitPrice || tp2 >= limitPrice) { Print("Skip SELL: TP not below entry."); return false; }
    if(limitPrice <= bid + g_stopsLevel) { Print("Skip SELL: limit too close to / below market."); return false; }
    if((slPrice - limitPrice) < g_stopsLevel) { Print("Skip SELL: SL inside stops level."); return false; }
    if((limitPrice - tp1) < g_stopsLevel) { Print("Skip SELL: TP1 inside stops level."); return false; }
    return true;
}

//+------------------------------------------------------------------+
//| Place a two-leg setup; rolls back leg 1 if leg 2 fails           |
//+------------------------------------------------------------------+
bool PlaceTwoLegSetup(bool isBuy, double legLot, double price, double sl, double tp1, double tp2)
{
    datetime expiration;
    ENUM_ORDER_TYPE_TIME timeType = ResolveExpiration(expiration);

    trade.SetExpertMagicNumber(Magic_TP1);
    bool ok1;
    if(isBuy) ok1 = trade.BuyLimit (legLot, price, _Symbol, sl, tp1, timeType, expiration, "Mustafa_FX 1");
    else      ok1 = trade.SellLimit(legLot, price, _Symbol, sl, tp1, timeType, expiration, "Mustafa_FX 1");

    bool  placed1 = ok1 && (trade.ResultRetcode() == TRADE_RETCODE_DONE ||
                            trade.ResultRetcode() == TRADE_RETCODE_PLACED);
    ulong ticket1 = trade.ResultOrder();
    if(!placed1) { PrintFormat("Leg 1 placement failed, retcode=%u", trade.ResultRetcode()); return false; }

    trade.SetExpertMagicNumber(Magic_TP2);
    bool ok2;
    if(isBuy) ok2 = trade.BuyLimit (legLot, price, _Symbol, sl, tp2, timeType, expiration, "Mustafa_FX 2");
    else      ok2 = trade.SellLimit(legLot, price, _Symbol, sl, tp2, timeType, expiration, "Mustafa_FX 2");

    bool placed2 = ok2 && (trade.ResultRetcode() == TRADE_RETCODE_DONE ||
                           trade.ResultRetcode() == TRADE_RETCODE_PLACED);
    if(!placed2)
    {
        PrintFormat("Leg 2 failed, retcode=%u. Rolling back leg 1 #%I64u.", trade.ResultRetcode(), ticket1);
        if(!trade.OrderDelete(ticket1))
            PrintFormat("Rollback delete failed #%I64u, retcode=%u", ticket1, trade.ResultRetcode());
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    ManageBreakEven();

    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    RefreshSymbolConstraints();
    if(g_minVol <= 0) return;

    // --- DATA ACQUISITION (validate every copy) ---
    double biasEma[], fEma[], sEma[], pEma[], atrArr[];
    ArraySetAsSeries(biasEma, true); ArraySetAsSeries(fEma, true);
    ArraySetAsSeries(sEma, true);    ArraySetAsSeries(pEma, true);
    ArraySetAsSeries(atrArr, true);

    if(CopyBuffer(biasEmaHandle, 0, 1, 1, biasEma) < 1) return;
    if(CopyBuffer(fastEmaHandle, 0, 1, 2, fEma)    < 2) return;
    if(CopyBuffer(slowEmaHandle, 0, 1, 1, sEma)    < 1) return;
    if(CopyBuffer(pullEmaHandle, 0, 1, 1, pEma)    < 1) return;
    if(CopyBuffer(atrHandle,     0, 1, 1, atrArr)  < 1) return;
    if(atrArr[0] <= 0) return;

    int ohlcDepth = BreakLookback + 5;                       // room for 3-bar FVG + swing window
    double high[], low[], close[], open[];
    ArraySetAsSeries(high, true);  ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true); ArraySetAsSeries(open, true);

    if(CopyHigh (_Symbol, _Period, 1, ohlcDepth, high)  < ohlcDepth) return;
    if(CopyLow  (_Symbol, _Period, 1, ohlcDepth, low)   < ohlcDepth) return;
    if(CopyClose(_Symbol, _Period, 1, ohlcDepth, close) < ohlcDepth) return;
    if(CopyOpen (_Symbol, _Period, 1, ohlcDepth, open)  < ohlcDepth) return;

    double atr = atrArr[0];

    // --- BIAS & TREND ---
    bool bullBias  = (close[0] > biasEma[0]);
    bool bullTrend = bullBias && (fEma[0] > sEma[0]) && (fEma[0] > fEma[1]);
    bool bearBias  = (close[0] < biasEma[0]);
    bool bearTrend = bearBias && (fEma[0] < sEma[0]) && (fEma[0] < fEma[1]);

    ManagePendingOrders(bullBias, bearBias);
    if(CountActiveSetups() >= MaxSetupsPerTimeframe) return;

    // --- SWING LEVELS ---
    double hiBefore = high[1]; double loBefore = low[1];
    for(int i = 1; i <= BreakLookback; i++)
    {
        if(high[i] > hiBefore) hiBefore = high[i];
        if(low[i]  < loBefore) loBefore = low[i];
    }

    // --- BREAKOUT TRIGGER ---
    double body = MathAbs(close[0] - open[0]);
    bool breakBodyOk = body >= (atr * MinBreakBodyAtr);
    bool bullBreakout = bullTrend && (close[0] > hiBefore) && (close[0] > open[0]) && breakBodyOk;
    bool bearBreakout = bearTrend && (close[0] < loBefore) && (close[0] < open[0]) && breakBodyOk;

    // --- SMC STRUCTURE MODULE: displacement gate + FVG data ---
    FvgInfo bullFvg = DetectBullFVG(high, low, close, open, atr);
    FvgInfo bearFvg = DetectBearFVG(high, low, close, open, atr);

    if(RequireDisplacement)
    {
        if(bullBreakout && !(bullFvg.exists && bullFvg.bodyStrong)) bullBreakout = false;
        if(bearBreakout && !(bearFvg.exists && bearFvg.bodyStrong)) bearBreakout = false;
    }

    // =========================================================================
    // EXECUTION
    // =========================================================================
    if(bullBreakout)
    {
        EntryPlan plan = BuildBullEntry(atr, loBefore, high, low, pEma, bullFvg);
        if(!plan.valid) { if(plan.reason != "") Print(plan.reason); return; }

        double limitPrice = NormalizePrice(plan.limitPrice);
        double slPrice    = NormalizePrice(plan.slPrice);
        double slDistance = MathAbs(limitPrice - slPrice);
        if(slDistance <= 0) return;
        double tp1Price   = NormalizePrice(limitPrice + (slDistance * TP1_RewardRatio));
        double tp2Price   = NormalizePrice(limitPrice + (slDistance * TP2_RewardRatio));

        if(!ValidateBuySetup(limitPrice, slPrice, tp1Price, tp2Price)) return;

        double totalLotSize = CalculateLotSize(limitPrice, slPrice);
        double legLot = NormalizeVolumeDown(totalLotSize / 2.0);
        if(legLot < g_minVol) { Print("BUY skipped: per-leg lot below minimum at current risk."); return; }

        PlaceTwoLegSetup(true, legLot, limitPrice, slPrice, tp1Price, tp2Price);
        return;
    }

    if(bearBreakout)
    {
        EntryPlan plan = BuildBearEntry(atr, hiBefore, high, low, pEma, bearFvg);
        if(!plan.valid) { if(plan.reason != "") Print(plan.reason); return; }

        double limitPrice = NormalizePrice(plan.limitPrice);
        double slPrice    = NormalizePrice(plan.slPrice);
        double slDistance = MathAbs(slPrice - limitPrice);
        if(slDistance <= 0) return;
        double tp1Price   = NormalizePrice(limitPrice - (slDistance * TP1_RewardRatio));
        double tp2Price   = NormalizePrice(limitPrice - (slDistance * TP2_RewardRatio));

        if(!ValidateSellSetup(limitPrice, slPrice, tp1Price, tp2Price)) return;

        double totalLotSize = CalculateLotSize(limitPrice, slPrice);
        double legLot = NormalizeVolumeDown(totalLotSize / 2.0);
        if(legLot < g_minVol) { Print("SELL skipped: per-leg lot below minimum at current risk."); return; }

        PlaceTwoLegSetup(false, legLot, limitPrice, slPrice, tp1Price, tp2Price);
        return;
    }
}
