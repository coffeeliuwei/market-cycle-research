import csv, math, statistics
from pathlib import Path
from datetime import date
root = Path(__file__).resolve().parents[1]
events = []
for market, lower, upper in [('CSI300TR',-2,2),('SPY',-.78,2),('BTC',.3,2.2)]:
    with (root/'state/cycle-weekly/v1'/f'{market}.csv').open(encoding='utf-8-sig') as f:
        rows = list(csv.DictReader(f))
    dates = [date.fromisoformat(r['week']) for r in rows]
    p = [float(r['price']) for r in rows]
    b = [float(r['benchmark']) for r in rows]
    ratios = [math.log(x/y) for x,y in zip(p,b)]
    z = [None]*156
    for i in range(156,len(p)):
        history = ratios[i-156:i]
        z.append(round((ratios[i]-statistics.mean(history))/statistics.stdev(history),3))
    pending = {}
    setups = {}
    pivot = {}
    candidates = {'low':0,'high':0}
    weight = .5
    next_weight = None
    wealth = [1.,1.,1.]
    peak = wealth.copy()
    dd = [0.,0.,0.]
    trades = 0
    start = 160
    for i in range(start,len(p)):
        if i>start:
            a,r = p[i]/p[i-1]-1,b[i]/b[i-1]-1
            for k,w in enumerate((weight,.5,1.)):
                wealth[k] *= 1+w*a+(1-w)*r
                peak[k] = max(peak[k],wealth[k])
                dd[k] = min(dd[k],wealth[k]/peak[k]-1)
        if next_weight is not None:
            trades += int(weight != next_weight)
            weight,next_weight = next_weight,None
        rank = sum(x<=p[i] for x in p[i-51:i+1])/52
        for side in ('low','high'):
            low = side=='low'
            extreme = min if low else max
            opposite = max if low else min
            j = i-4
            if p[j]==extreme(p[j-4:i+1]):
                pivot[side]=j
            if (rank<=.2 and z[i]<=lower) if low else (rank>=.8 and z[i]>=upper):
                pending[side]=i
            if side in setups:
                stamp,level=setups[side]
                if i-stamp>13:
                    del setups[side]
                elif dates[i].month!=dates[i-1].month and i-1>stamp and (p[i-1]>level if low else p[i-1]<level):
                    next_weight = .75 if low else .25
                    events.append((market,side,dates[stamp],dates[i],dates[i+1] if i+1<len(p) else 'pending',level))
                    del setups[side]
                    pending.pop(side,None)
            j=pivot.get(side)
            if j is None or side in setups or i-pending.get(side,-999)>13:
                continue
            divergent=(p[i]<=p[j] and z[i]>z[j]) if low else (p[i]>=p[j] and z[i]<z[j])
            if divergent:
                candidates[side]+=1
                setups[side]=(i,opposite(p[j+1:i]))
    years=(dates[-1]-dates[start]).days/365.2425
    print(market,dates[start],dates[-1],candidates,'confirmed',[(s,sum(e[:2]==(market,s) for e in events)) for s in ('low','high')],'changes',trades,'CAGR/MDD',[(round((v**(1/years)-1)*100,2),round(d*100,2)) for v,d in zip(wealth,dd)])
with (root/'state/runtime/z-confirmation.csv').open('w',newline='',encoding='utf-8-sig') as f:
    writer=csv.writer(f)
    writer.writerow(['market','side','divergence_week','decision_week','execution_week','intervening_price'])
    writer.writerows(events)

