//+------------------------------------------------------------------+
//|                                                已实现波动率权重.mq5 |
//|                                  Copyright 2026, 最终修正版       |
//|                                            限定显示范围 + 曲线修正 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.30"
#property indicator_separate_window
#property indicator_buffers 1
#property indicator_plots   1

#property indicator_label1  "Weight"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- 输入参数
input int            StartHour       = 1;               // 时段开始小时
input int            StartMinute     = 0;               // 时段开始分钟
input int            EndHour         = 1;               // 时段结束小时
input int            EndMinute       = 30;              // 时段结束分钟
input ENUM_TIMEFRAMES InputPeriod    = PERIOD_M5;       // 计算RV所用的K线周期（手动填写）
input int            HistoryDays     = 14;              // 历史天数（计算方差）
input int            DisplayDays     = 20;              // 显示天数（控制图表上保留的权重点数量）
input bool           UseLogReturns   = true;            // true=对数收益率，false=简单收益率
input int            WeightDivisor   = 0;               // 除数：0=标准差，1=方差
input bool           ShowDetails     = true;            // 显示详细信息

//--- 全局变量
double         WeightBuffer[];                         // 指标缓冲区
string         InfoLabelName = "RVW_Info";             // 文本标签名称
double         CurrentWeight = 0.0;                    // 最新权重值
datetime       LastWeightUpdateTime = 0;               // 最新权重生效时间（时段结束时间）
int            lastCalcDate = 0;                       // 上次计算的日期 (YYYYMMDD)
string         DetailsText = "";                       // 详细信息文本

//--- 存储历史权重点（按时间升序，最多DisplayDays个）
struct WeightPoint
{
   datetime      effectiveTime;   // 该权重开始生效的时间（对应时段结束时间）
   double        weight;          // 权重值
};
WeightPoint    WeightHistory[];                        // 历史权重序列（最多DisplayDays个）

//+------------------------------------------------------------------+
//| 获取指定日期的时段开始时间                                          |
//+------------------------------------------------------------------+
datetime GetSegmentStartTime(datetime dayStart)
{
   MqlDateTime dt;
   TimeToStruct(dayStart, dt);
   dt.hour = StartHour;
   dt.min  = StartMinute;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| 获取指定日期的时段结束时间                                          |
//+------------------------------------------------------------------+
datetime GetSegmentEndTime(datetime dayStart)
{
   MqlDateTime dt;
   TimeToStruct(dayStart, dt);
   dt.hour = EndHour;
   dt.min  = EndMinute;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| 计算指定时段内的已实现波动率 (RV)                                   |
//+------------------------------------------------------------------+
bool CalculateRV(datetime segStart, datetime segEnd, double &rv)
{
   double closePrices[];
   // 复制从 segStart 到 segEnd 之间的所有K线（包括起点，不包括终点？CopyClose的第三个参数是开始时间，第四个是结束时间，包含开始不包含结束？实际测试：按时间范围复制，包含边界）
   int copied = CopyClose(Symbol(), InputPeriod, segStart, segEnd, closePrices);
   if(copied < 2)
   {
      Print("时段内 K线数量不足: ", copied, " (需要至少2根)");
      return false;
   }
   
   double sumSq = 0.0;
   for(int i = 1; i < copied; i++)
   {
      double ret;
      if(UseLogReturns)
         ret = MathLog(closePrices[i] / closePrices[i-1]);
      else
         ret = (closePrices[i] - closePrices[i-1]) / closePrices[i-1];
      sumSq += ret * ret;
   }
   
   rv = sumSq;
   return true;
}

//+------------------------------------------------------------------+
//| 收集指定日期之前的历史RV序列（用于计算该日期的统计量）                |
//| 参数: baseDayStart - 基准日期的零点，收集该日期之前的 HistoryDays 天 |
//+------------------------------------------------------------------+
int CollectHistoricalRV(datetime baseDayStart, double &rvArray[])
{
   ArrayResize(rvArray, 0);
   datetime curDayStart = baseDayStart - 86400;  // 从昨日开始
   int collected = 0;
   int maxAttempts = HistoryDays * 3;
   int attempts = 0;
   
   while(collected < HistoryDays && attempts < maxAttempts)
   {
      datetime segStart = GetSegmentStartTime(curDayStart);
      datetime segEnd   = GetSegmentEndTime(curDayStart);
      
      // 只使用已经完成的时段（segEnd <= 当前时间）
      if(segEnd <= TimeCurrent())
      {
         double rv;
         if(CalculateRV(segStart, segEnd, rv))
         {
            ArrayResize(rvArray, collected+1);
            rvArray[collected] = rv;
            collected++;
         }
      }
      
      curDayStart -= 86400;
      attempts++;
   }
   
   return collected;
}

//+------------------------------------------------------------------+
//| 计算指定日期（dayStart零点）的权重值                                 |
//| 输出 weight 和 effectiveTime（时段结束时间）                        |
//| 返回 true 表示成功                                                 |
//+------------------------------------------------------------------+
bool CalculateWeightForDate(datetime dayStart, double &weight, datetime &effectiveTime)
{
   datetime segStart = GetSegmentStartTime(dayStart);
   datetime segEnd   = GetSegmentEndTime(dayStart);
   effectiveTime = segEnd;
   
   // 如果时段结束时间大于当前时间（未来时段），不计算
   if(segEnd > TimeCurrent())
      return false;
   
   // 1. 收集该日期之前的历史RV序列（用于统计量）
   double histRV[];
   int histCount = CollectHistoricalRV(dayStart, histRV);
   if(histCount < 2)
   {
      Print("日期 ", TimeToString(dayStart), " 有效历史交易日不足2天，跳过");
      return false;
   }
   
   // 2. 计算均值和方差/标准差
   double sum = 0.0;
   for(int i = 0; i < histCount; i++)
      sum += histRV[i];
   double mean = sum / histCount;
   
   double sqSum = 0.0;
   for(int i = 0; i < histCount; i++)
      sqSum += (histRV[i] - mean) * (histRV[i] - mean);
   double variance = sqSum / (histCount - 1);
   double stdDev = MathSqrt(variance);
   
   // 3. 计算该日期的RV
   double rvToday;
   if(!CalculateRV(segStart, segEnd, rvToday))
   {
      Print("日期 ", TimeToString(dayStart), " 计算RV失败");
      return false;
   }
   
   // 4. 计算权重
   double divisor = (WeightDivisor == 0) ? stdDev : variance;
   if(divisor == 0.0)
      weight = 0.0;
   else
      weight = rvToday / divisor;
   
   return true;
}

//+------------------------------------------------------------------+
//| 预加载历史权重（最近DisplayDays天，不包括未来时段）                   |
//+------------------------------------------------------------------+
void PreloadHistoricalWeights()
{
   ArrayResize(WeightHistory, 0);
   
   datetime now = TimeCurrent();
   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);
   datetime todayStart = StringToTime(TimeToString(now, TIME_DATE));
   
   // 从今天开始向前回溯，直到收集到 DisplayDays 个有效权重，或回溯超过 DisplayDays*2 天
   int collected = 0;
   int maxDaysBack = DisplayDays * 2;  // 避免无限循环
   int daysBack = 0;
   datetime curDayStart = todayStart;
   
   while(collected < DisplayDays && daysBack <= maxDaysBack)
   {
      double weight;
      datetime effTime;
      if(CalculateWeightForDate(curDayStart, weight, effTime))
      {
         // 插入到数组头部（保持时间升序）
         int newSize = ArraySize(WeightHistory) + 1;
         ArrayResize(WeightHistory, newSize);
         // 向后移动现有元素
         for(int i = newSize - 1; i > 0; i--)
            WeightHistory[i] = WeightHistory[i-1];
         WeightHistory[0].effectiveTime = effTime;
         WeightHistory[0].weight = weight;
         collected++;
      }
      curDayStart -= 86400;
      daysBack++;
   }
   
   // 如果收集的数量超过 DisplayDays，只保留最近的 DisplayDays 个（数组已是升序，保留后DisplayDays个）
   int total = ArraySize(WeightHistory);
   if(total > DisplayDays)
   {
      int keep = DisplayDays;
      for(int i = 0; i < keep; i++)
         WeightHistory[i] = WeightHistory[total - keep + i];
      ArrayResize(WeightHistory, keep);
   }
   
   Print("预加载完成，共加载 ", ArraySize(WeightHistory), " 个历史权重");
}

//+------------------------------------------------------------------+
//| 每日核心计算函数（只在时段结束后执行一次，更新今日权重）               |
//+------------------------------------------------------------------+
void UpdateTodayWeight()
{
   datetime now = TimeCurrent();
   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);
   datetime todayStart = StringToTime(TimeToString(now, TIME_DATE));
   
   datetime segStartToday = GetSegmentStartTime(todayStart);
   datetime segEndToday   = GetSegmentEndTime(todayStart);
   
   // 时段尚未结束，不计算
   if(now < segEndToday)
      return;
   
   int todayDate = (int)(now / 86400);
   if(lastCalcDate == todayDate)
      return;
   
   // 计算今日权重
   double weight;
   datetime effTime;
   if(CalculateWeightForDate(todayStart, weight, effTime))
   {
      CurrentWeight = weight;
      LastWeightUpdateTime = effTime;
      
      // 更新历史权重数组：如果已有相同 effectiveTime 则替换，否则添加并保持长度 <= DisplayDays
      int idx = -1;
      for(int i = 0; i < ArraySize(WeightHistory); i++)
      {
         if(WeightHistory[i].effectiveTime == effTime)
         {
            idx = i;
            break;
         }
      }
      if(idx >= 0)
      {
         WeightHistory[idx].weight = weight;
      }
      else
      {
         int newSize = ArraySize(WeightHistory) + 1;
         ArrayResize(WeightHistory, newSize);
         WeightHistory[newSize-1].effectiveTime = effTime;
         WeightHistory[newSize-1].weight = weight;
         // 按时间排序（升序）
         for(int i = newSize-1; i > 0; i--)
         {
            if(WeightHistory[i].effectiveTime < WeightHistory[i-1].effectiveTime)
            {
               WeightPoint temp = WeightHistory[i];
               WeightHistory[i] = WeightHistory[i-1];
               WeightHistory[i-1] = temp;
            }
            else break;
         }
         // 限制长度
         if(ArraySize(WeightHistory) > DisplayDays)
         {
            int removeCount = ArraySize(WeightHistory) - DisplayDays;
            for(int i = 0; i < DisplayDays; i++)
               WeightHistory[i] = WeightHistory[i + removeCount];
            ArrayResize(WeightHistory, DisplayDays);
         }
      }
      
      // 准备详细信息文本（用于显示）
      // 为了显示今日统计量，需要重新获取一些中间值，这里简化，只显示基本数据
      double histRV[];
      int histCount = CollectHistoricalRV(todayStart, histRV);
      double mean=0, variance=0, stdDev=0;
      if(histCount>=2)
      {
         double sum=0;
         for(int i=0;i<histCount;i++) sum+=histRV[i];
         mean=sum/histCount;
         double sqSum=0;
         for(int i=0;i<histCount;i++) sqSum+=(histRV[i]-mean)*(histRV[i]-mean);
         variance=sqSum/(histCount-1);
         stdDev=MathSqrt(variance);
      }
      double rvToday=0;
      CalculateRV(segStartToday, segEndToday, rvToday);
      
      DetailsText = StringFormat(
         "已实现波动率权重指标 (显示范围:%d天)\n"
         "时段: %02d:%02d - %02d:%02d\n"
         "计算周期: %s\n"
         "历史交易日(用于统计): %d (有效: %d)\n"
         "历史RV均值: %.8f\n"
         "历史RV标准差: %.8f\n"
         "历史RV方差: %.8f\n"
         "今日RV: %.8f\n"
         "除数类型: %s\n"
         "最新权重 = %.6f\n"
         "最后计算: %s",
         DisplayDays,
         StartHour, StartMinute, EndHour, EndMinute,
         EnumToString(InputPeriod),
         HistoryDays, histCount,
         mean, stdDev, variance,
         rvToday,
         (WeightDivisor == 0) ? "标准差" : "方差",
         CurrentWeight,
         TimeToString(now)
      );
      
      if(ShowDetails && ObjectFind(0, InfoLabelName) >= 0)
      {
         ObjectSetString(0, InfoLabelName, OBJPROP_TEXT, DetailsText);
      }
      
      lastCalcDate = todayDate;
      Print("每日计算完成，日期: ", TimeToString(todayStart), " 权重 = ", CurrentWeight);
   }
}

//+------------------------------------------------------------------+
//| 根据K线时间获取应显示的权重值（超出历史范围返回EMPTY_VALUE）          |
//+------------------------------------------------------------------+
double GetWeightAtTime(datetime barTime)
{
   int size = ArraySize(WeightHistory);
   if(size == 0)
      return EMPTY_VALUE;
   
   // 二分查找或线性查找最后一个 effectiveTime <= barTime
   int idx = -1;
   for(int i = size-1; i >= 0; i--)
   {
      if(WeightHistory[i].effectiveTime <= barTime)
      {
         idx = i;
         break;
      }
   }
   
   return (idx >= 0) ? WeightHistory[idx].weight : EMPTY_VALUE;
}

//+------------------------------------------------------------------+
//| 填充指标缓冲区（只填充指定范围）                                     |
//+------------------------------------------------------------------+
void FillWeightBuffer(int startPos, int count)
{
   if(count <= 0) return;
   if(startPos < 0) startPos = 0;
   
   datetime timeArray[];
   int copied = CopyTime(Symbol(), Period(), startPos, count, timeArray);
   if(copied <= 0)
   {
      Print("CopyTime 失败: startPos=", startPos, " count=", count, " error=", GetLastError());
      return;
   }
   
   for(int i = 0; i < copied; i++)
   {
      int bufferIndex = startPos + i;
      if(bufferIndex >= ArraySize(WeightBuffer))
         break;
      WeightBuffer[bufferIndex] = GetWeightAtTime(timeArray[i]);
   }
}

//+------------------------------------------------------------------+
//| 指标初始化                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, WeightBuffer, INDICATOR_DATA);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   
   // 时段简单校验
   int segLenMin = (EndHour * 60 + EndMinute) - (StartHour * 60 + StartMinute);
   if(segLenMin <= 0)
      Print("警告：时段结束时间必须大于开始时间（未考虑跨日）");
   
   if(ShowDetails)
   {
      ObjectCreate(0, InfoLabelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, InfoLabelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, InfoLabelName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, InfoLabelName, OBJPROP_YDISTANCE, 30);
      ObjectSetString(0, InfoLabelName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, InfoLabelName, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, InfoLabelName, OBJPROP_COLOR, clrWhite);
   }
   
   // 预加载历史权重
   PreloadHistoricalWeights();
   
   // 更新今日权重（如果时段已结束）
   UpdateTodayWeight();
   
   // 填充整个缓冲区
   int total = Bars(Symbol(), Period());
   if(total > 0)
   {
      ArrayResize(WeightBuffer, total);
      FillWeightBuffer(0, total);
   }
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // 尝试更新今日权重（一天一次）
   UpdateTodayWeight();
   
   // 刷新缓冲区中的最新值
   if(prev_calculated < rates_total)
   {
      int start = (prev_calculated > 0) ? prev_calculated - 1 : 0;
      int count = rates_total - start;
      FillWeightBuffer(start, count);
   }
   else
   {
      // 无新K线时，确保最新K线权重正确
      if(rates_total > 0 && WeightBuffer[rates_total-1] != CurrentWeight)
         WeightBuffer[rates_total-1] = CurrentWeight;
   }
   
   return rates_total;
}

//+------------------------------------------------------------------+
//| 释放标签                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, InfoLabelName);
}
//+------------------------------------------------------------------+