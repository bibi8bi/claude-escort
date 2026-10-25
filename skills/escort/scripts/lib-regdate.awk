# lib-regdate.awk —— task_plan 条目「登记日期」的抓取与天数计算,由 task-tree.sh 拼接调用。
# dfc 用的是 Howard Hinnant 的 days_from_civil 算法。
function dfc(y,m,d,  era,yoe,doy,doe){          # 公历日 → 天序号(mawk 没有 mktime,自己算)
  if (m<=2) y--
  era = int((y>=0?y:y-399)/400); yoe = y - era*400
  doy = int((153*(m + (m>2?-3:9)) + 2)/5) + d - 1
  doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy
  return era*146097 + doe - 719468
}

function getdate(t,  s,ym,seg){
  s=t
  while (match(s,/(19|20)[0-9][0-9]-(0[1-9]|1[0-2])/)) {
    ym=substr(s,RSTART,7); if (ym > TY "-" TM) return "排期"
    s=substr(s,RSTART+RLENGTH)
  }
  if (match(t,/(19|20)[0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])/)) return substr(t,RSTART,10)
  if (match(t,/(^|[^0-9-])(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])([^0-9-]|$)/)) {
    seg=substr(t,RSTART,RLENGTH)
    if (match(seg,/(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])/)) return TY "-" substr(seg,RSTART,5)
  }
  return ""
}
