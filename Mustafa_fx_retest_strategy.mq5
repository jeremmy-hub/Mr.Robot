//+------------------------------------------------------------------+
//|               Mustafa_FX_retest_strategy.mq5                     |
//+------------------------------------------------------------------+
#property copyright "Mustafa_FX"
#property link      ""
#property version   "4.00"
#property description "Mustafa_FX Retest Strategy - Bias Aligned"

#include <Trade\Trade.mqh>

//--- Main Trade Inputs
input double   RiskPercent           = 1.0;       // Total Risk per trade (%)
input double   TP1_RewardRatio       = 1.0;       // Position 1 TP (R-Multiple)
input double   TP2_RewardRatio       = 1.5;       // Position 2 TP (R-Multiple)
input double   BE_Activation_Percent = 50.0;      // Move SL to Entry when price reaches this % of TP1
input ulong    BaseMagicNumber       = 123456;    // Base Magic Number
input int      MaxSetupsPerTimeframe = 1;         // Max concurrent setups PER timeframe

//--- Master Bias & Trend Inputs
input int      BiasEmaLen            = 200;       // Master Trend Bias EMA
input int      FastEmaLen            = 34;        // Fast Trend EMA
input int      SlowEmaLen            = 144;       // Slow Trend EMA
input int      PullEmaLen            = 21;        // Pullback Target EMA

//--- Breakout & Execution Inputs
input int      AtrLen                = 14;        // ATR Length
input int      BreakLookback         = 20;        // Breakout Swing Lookback
input double   MinBreakBodyAtr       = 0.20;      // Min Breakout Body / ATR
input double   EntryDepthAtr         = 0.40;      // Entry Depth into pullback (ATR)
input double   SlBufferAtr           = 0.30;      // Stop Loss buffer beyond swing (ATR)
input int      MaxHuntBars           = 40;        // Max bars before limit order expires

//--- Global Objects & Handles
CTrade         trade;
datetime       lastBarTime;
int            biasEmaHandle, fastEmaHandle, slowEmaHandle, pullEmaHandle, atrHandle;

//--- Timeframe-Aware Magic Numbers
ulong          Magic_TP1, Magic_TP2;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Generate Unique Magic Numbers based on the timeframe
    Magic_TP1 = BaseMagicNumber + PeriodSeconds(_Period);
    Magic_TP2 = Magic_TP1 + 1;

    // Initialize Indicators
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
    
    Print("Mustafa_FX_retest_strategy Initialized Successfully.");
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
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double slPrice)
{
    double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double slDistance = MathAbs(entryPrice - slPrice);
    if(slDistance == 0) return 0;
    double lossInTicks = slDistance / tickSize;
    return riskAmount / (lossInTicks * tickValue);
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
        ulong m = PositionGetInteger(POSITION_MAGIC);
        
        // Ensure the trade belongs to this specific timeframe's EA
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && (m == Magic_TP1 || m == Magic_TP2))
        {
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl    = PositionGetDouble(POSITION_SL);
            double tp    = PositionGetDouble(POSITION_TP);
            long type    = PositionGetInteger(POSITION_TYPE);
            
            if(tp == 0) continue; 
            
            double fullTpDistance = MathAbs(tp - entry);
            if(fullTpDistance == 0) continue;
            
            // Normalize the activation distance based on TP1
            double targetDistance = fullTpDistance;
            if(m == Magic_TP2 && TP2_RewardRatio > 0) {
                targetDistance = (fullTpDistance / TP2_RewardRatio) * TP1_RewardRatio;
            }
            
            double activationDist = targetDistance * (BE_Activation_Percent / 100.0);
            
            if(type == POSITION_TYPE_BUY)
            {
                double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                // If price reached the trigger %, and SL is not already moved to (or above) entry
                if(currentBid >= (entry + activationDist) && sl < entry)
                {
                    if(entry - currentBid < -minStopLevel) // Broker compliance check
                        trade.PositionModify(ticket, entry, tp);
                }
            }
            else if(type == POSITION_TYPE_SELL)
            {
                double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                // If price reached the trigger %, and SL is not already moved to (or below) entry
                if(currentAsk <= (entry - activationDist) && (sl > entry || sl == 0))
                {
                    if(currentAsk - entry < -minStopLevel) // Broker compliance check
                        trade.PositionModify(ticket, entry, tp);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    ManageBreakEven();

    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(currentBarTime == lastBarTime) return; 
    
    // --- Count active setups for this timeframe ---
    int tradesCount = 0;
    
    for(int i=0; i<PositionsTotal(); i++) {
        PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
            ulong m = PositionGetInteger(POSITION_MAGIC);
            if(m == Magic_TP1 || m == Magic_TP2) tradesCount++;
        }
    }
    for(int i=0; i<OrdersTotal(); i++) {
        OrderGetTicket(i);
        if(OrderGetString(ORDER_SYMBOL) == _Symbol) {
            ulong m = OrderGetInteger(ORDER_MAGIC);
            if(m == Magic_TP1 || m == Magic_TP2) tradesCount++;
        }
    }
    
    int activeSetups = tradesCount / 2; // 1 Setup = 2 Trades (TP1 and TP2)
    if(activeSetups >= MaxSetupsPerTimeframe) return;

    double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    // =========================================================================
    // BIAS-ALIGNED RETEST STRATEGY
    // =========================================================================
    
    double biasEma[], fEma[], sEma[], pEma[], atrArr[];
    ArraySetAsSeries(biasEma, true); ArraySetAsSeries(fEma, true); 
    ArraySetAsSeries(sEma, true); ArraySetAsSeries(pEma, true); ArraySetAsSeries(atrArr, true);
    
    CopyBuffer(biasEmaHandle, 0, 1, 1, biasEma);
    CopyBuffer(fastEmaHandle, 0, 1, 2, fEma);
    CopyBuffer(slowEmaHandle, 0, 1, 1, sEma);
    CopyBuffer(pullEmaHandle, 0, 1, 1, pEma);
    CopyBuffer(atrHandle, 0, 1, 1, atrArr);
    
    double high[], low[], close[], open[];
    ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); 
    ArraySetAsSeries(close, true); ArraySetAsSeries(open, true);
    
    CopyHigh(_Symbol, _Period, 1, BreakLookback + 1, high);
    CopyLow(_Symbol, _Period, 1, BreakLookback + 1, low);
    CopyClose(_Symbol, _Period, 1, 2, close);
    CopyOpen(_Symbol, _Period, 1, 2, open);
    
    double body = MathAbs(close[0] - open[0]);
    bool breakBodyOk = body >= (atrArr[0] * MinBreakBodyAtr);
    
    // --- BIAS & TREND CONDITIONS ---
    bool bullBias  = (close[0] > biasEma[0]); // Master Bias
    bool bullTrend = bullBias && (fEma[0] > sEma[0]) && (fEma[0] > fEma[1]); 
    
    bool bearBias  = (close[0] < biasEma[0]); // Master Bias
    bool bearTrend = bearBias && (fEma[0] < sEma[0]) && (fEma[0] < fEma[1]);
    
    // --- SWING LEVELS ---
    double hiBefore = high[1]; double loBefore = low[1];
    for(int i=1; i<=BreakLookback; i++) {
        if(high[i] > hiBefore) hiBefore = high[i];
        if(low[i] < loBefore) loBefore = low[i];
    }
    
    // --- BREAKOUT CONDITIONS ---
    bool bullBreakout = bullTrend && (close[0] > hiBefore) && (close[0] > open[0]) && breakBodyOk;
    bool bearBreakout = bearTrend && (close[0] < loBefore) && (close[0] < open[0]) && breakBodyOk;

    // --- EXECUTION ---
    if(bullBreakout)
    {
        double limitPrice = pEma[0] - (EntryDepthAtr * atrArr[0]);
        double slPrice = loBefore - (SlBufferAtr * atrArr[0]);
        double slDistance = MathAbs(limitPrice - slPrice);
        double tp1Price = limitPrice + (slDistance * TP1_RewardRatio);
        double tp2Price = limitPrice + (slDistance * TP2_RewardRatio);
        
        double totalLotSize = CalculateLotSize(limitPrice, slPrice);
        if(totalLotSize >= minVol * 2)
        {
            double pos1Lot = MathFloor((totalLotSize / 2.0) / volumeStep) * volumeStep;
            if(pos1Lot < minVol) pos1Lot = minVol;
            double pos2Lot = totalLotSize - pos1Lot; 
            
            datetime expiration = TimeCurrent() + (MaxHuntBars * PeriodSeconds(_Period));
            
            trade.SetExpertMagicNumber(Magic_TP1);
            trade.BuyLimit(pos1Lot, limitPrice, _Symbol, slPrice, tp1Price, ORDER_TIME_SPECIFIED, expiration, "Mustafa_FX Buy 1");
            trade.SetExpertMagicNumber(Magic_TP2);
            trade.BuyLimit(pos2Lot, limitPrice, _Symbol, slPrice, tp2Price, ORDER_TIME_SPECIFIED, expiration, "Mustafa_FX Buy 2");
            
            lastBarTime = currentBarTime; 
            return; 
        }
    }
    
    if(bearBreakout)
    {
        double limitPrice = pEma[0] + (EntryDepthAtr * atrArr[0]);
        double slPrice = hiBefore + (SlBufferAtr * atrArr[0]);
        double slDistance = MathAbs(slPrice - limitPrice);
        double tp1Price = limitPrice - (slDistance * TP1_RewardRatio);
        double tp2Price = limitPrice - (slDistance * TP2_RewardRatio);
        
        double totalLotSize = CalculateLotSize(limitPrice, slPrice);
        if(totalLotSize >= minVol * 2)
        {
            double pos1Lot = MathFloor((totalLotSize / 2.0) / volumeStep) * volumeStep;
            if(pos1Lot < minVol) pos1Lot = minVol;
            double pos2Lot = totalLotSize - pos1Lot; 
            
            datetime expiration = TimeCurrent() + (MaxHuntBars * PeriodSeconds(_Period));
            
            trade.SetExpertMagicNumber(Magic_TP1);
            trade.SellLimit(pos1Lot, limitPrice, _Symbol, slPrice, tp1Price, ORDER_TIME_SPECIFIED, expiration, "Mustafa_FX Sell 1");
            trade.SetExpertMagicNumber(Magic_TP2);
            trade.SellLimit(pos2Lot, limitPrice, _Symbol, slPrice, tp2Price, ORDER_TIME_SPECIFIED, expiration, "Mustafa_FX Sell 2");
            
            lastBarTime = currentBarTime; 
            return;
        }
    }
}