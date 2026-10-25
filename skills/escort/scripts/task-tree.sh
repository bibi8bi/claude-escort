#!/usr/bin/env bash
# task-tree.sh —— 把当前项目 task_plan.md 的进度渲染成纯文字树。规则见 SKILL.md「丁、任务树」。
# 用法:bash task-tree.sh [--base <本会话基线 commit>] [--plan <路径>] [--out <路径>] [--全]
set -u
export LC_ALL=C.UTF-8   # 中文按字符截断要它;mawk 是字节型,截断交给 sed 做

BASE=""; OUT=""; PLAN=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --plan) PLAN="${2:-}"; shift 2 ;;
    --out)  OUT="${2:-}";  shift 2 ;;
    --全|--all) ALL=1; shift ;;
    -h|--help) echo "用法: task-tree.sh [--base <commit>] [--plan <路径>] [--out <路径>] [--全]"; exit 0 ;;
    *) echo "未知参数:$1" >&2; exit 2 ;;
  esac
done

DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -z "$PLAN" ]; then
  PLAN="$DIR/task_plan.md"
  [ -f "$PLAN" ] || PLAN="$DIR/planning/task_plan.md"   # 有的仓把 planning 文件放子目录
fi
[ -f "$PLAN" ] || { echo "找不到 task_plan.md(试过 $PLAN)" >&2; exit 1; }
PDIR=$(cd "$(dirname "$PLAN")" && pwd)
PLAN="$PDIR/$(basename "$PLAN")"

PROJ=$(git -C "$PDIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$PROJ" ]; then PROJ=$(basename "$PROJ"); else PROJ=$(basename "$PDIR"); fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
DF="$TMP/diff"; : > "$DF"
if [ -n "$BASE" ]; then
  if ! git -C "$PDIR" diff "$BASE" -- "$PLAN" > "$DF" 2>"$TMP/err"; then
    echo "[⚠ git diff 失败] 基线 $BASE 取不到,本次不标 ★:$(head -1 "$TMP/err")" >&2
    : > "$DF"; BASE=""
  fi
fi

TS="$TMP/ts"; : > "$TS"
git -C "$PDIR" blame --line-porcelain -- "$PLAN" 2>/dev/null \
  | awk '/^[0-9a-f]+ [0-9]+ [0-9]+/ && length($1)==40 { ln=$3 }
         /^committer-time / { ct=$2 }
         /^committer-tz /   { if (ln!="") { s=(substr($2,1,1)=="-")?-1:1
                                            print ln, int((ct + s*(substr($2,2,2)*3600 + substr($2,4,2)*60))/86400) }
                              ln="" }' > "$TS" || : > "$TS"

头部() {
  local done_n todo_n sub_done sub_todo total today_n ZD g
  done_n=$(grep -c '^- \[[xX]\]' "$PLAN" || true)
  todo_n=$(grep -c '^- \[ \]' "$PLAN" || true)
  sub_done=$(grep -c '^[[:space:]]\+- \[[xX]\]' "$PLAN" || true)
  sub_todo=$(grep -c '^[[:space:]]\+- \[ \]' "$PLAN" || true)
  total=$((done_n + todo_n))
  today_n=$(git -C "$PDIR" log HEAD --oneline --since=midnight 2>/dev/null | wc -l)
  printf '📍 %s · %s · 今日提交 %s 条(打勾是自己说的,提交才是实际做了)\n' "$PROJ" "$(date +%F)" "$today_n"
  ZD=$(grep -m1 -E '^- \*{0,2}终点\*{0,2}(:|：)' "$PLAN" || true)
  if [ -n "$ZD" ]; then
    ZD=${ZD#- }; ZD=${ZD//\*\*/}
    printf '⭐ %s\n' "$ZD"
  else
    echo "⭐ 缺终点行:建议在 task_plan.md 加一行 \`- 终点:<这个项目做完是什么样>\`"
  fi
  if [ "$total" -gt 0 ]; then
    g="📊 大活 已完 ${done_n} / 未完 ${todo_n}"
    [ $((sub_done + sub_todo)) -gt 0 ] && g="${g} · 小步 已完 ${sub_done} / 未完 ${sub_todo}"
  else
    g="📊 本仓无 checkbox 格子"
  fi
  printf '%s\n' "$g"
}

尾部() {
  echo "(数字由脚本数格子和 git 得出;正在干的活没登记进 task_plan 就算支线,动手前先登记)"
}

render() {
头部
LIB="${BASH_SOURCE[0]%/*}/lib-regdate.awk"
[ -f "$LIB" ] || { echo "缺 $LIB —— 登记日期口径的唯一真相源不在,不猜日期" >&2; exit 1; }
LIBAWK=$(cat "$LIB")
CAP=30
awk -v DF="$DF" -v TSF="$TS" -v TODAYN="$(( $(date -u -d "$(date +%F) 00:00:00" +%s) / 86400 ))" -v BASE="$BASE" -v PROJ="$PROJ" -v ALL="$ALL" -v CAP="$CAP" \
    -v TY="$(date +%Y)" -v TM="$(date +%m)" -v TD="$(date +%d)" "$LIBAWK"'
function key(s){                                # 认 ★ 用的行标识:剥掉勾选框后的前 60 字节
  sub(/^[ \t]*- \[[ xX]\][ \t]*/,"",s); return substr(s,1,60)
}
function stat(line){                             # 四态映射
  if (line ~ /^[ \t]*- \[[xX]\]/) return "[\342\234\223]"
  if (index(line,"阻塞:")>0) return "[!]"
  if (index(line,"进行中")>0) return "[\342\206\222]"
  return "[ ]"
}
function name(line,  c){                         # 子任务显示名
  c=line; sub(/^[ \t]*- \[[ xX]\][ \t]*/,"",c); gsub(/\*\*/,"",c); sub(/[ \t]+$/,"",c); return c
}
function title(line,  c,p,q){                    # 顶层标题:行首 **...**,没有粗体就取到第一个 —— 或 : 或 :
  c=line; sub(/^- \[[ xX]\][ \t]*/,"",c)
  if (substr(c,1,2)=="**") { c=substr(c,3); p=index(c,"**"); if(p>1) c=substr(c,1,p-1) }
  else {
    p=index(c,"——"); q=index(c,"\357\274\232"); if(q>0 && (p==0 || q<p)) p=q
    q=index(c,":");  if(q>0 && (p==0 || q<p)) p=q
    if (p>1) c=substr(c,1,p-1)
  }
  gsub(/\*\*/,"",c); sub(/[ \t]+$/,"",c); return c
}
function wrap(s){ return "\001" s "\002" }       # 交给管道末端的 sed 按「字符」截断(mawk 是字节的)

FILENAME==TSF { ts[$1+0]=$2+0; next }
FILENAME==DF {
  if ($0 ~ /^(\+\+\+|---)/) next
  if ($0 ~ /^\+[ \t]*- \[[xX]\][ \t]/)  newdone[key(substr($0,2))]=1
  if ($0 ~ /^-[ \t]*- \[ \][ \t]/)      oldtodo[key(substr($0,2))]=1
  if ($0 ~ /^\+[ \t]*- \[ \][ \t]/ && index($0,"阻塞:")>0) addblk[key(substr($0,2))]=1
  if ($0 ~ /^-[ \t]*- \[ \][ \t]/ && index($0,"阻塞:")>0) oldblk[key(substr($0,2))]=1
  next
}
{ L[++N]=$0 }

END {
  for (k in newdone) if (k in oldtodo) star[k]=1
  for (k in addblk)  if (!(k in oldblk)) nblk[k]=1

  tn=0
  for (i=1;i<=N;i++) if (L[i] ~ /^- \[[ xX]\][ \t]/) ti[++tn]=i
  if (tn==0) { print "(本仓 task_plan 无 checkbox 格子——看终点与提交)"; exit }
  un=0
  for (t=1;t<=tn;t++) if (L[ti[t]] ~ /^- \[ \][ \t]/) ui[++un]=ti[t]
  if (un==0) { print "[\342\234\223] 所有任务已完成"; exit }

  for (u=1;u<=un;u++) {
    p=ui[u]; m=0
    for (j=p+1;j<=N;j++) {
      if (L[j] ~ /^- \[[ xX]\][ \t]/ || L[j] ~ /^#/) break
      if (L[j] ~ /^[ \t]+- \[[ xX]\][ \t]/) {
        m++; cl[u,m]=L[j]
        ind=match(L[j],/[^ \t]/)-1; d=int(ind/2); if(d<1)d=1; if(d>3)d=3; cd[u,m]=d
      }
    }
    cm[u]=m
  }

  for (u=1;u<=un;u++) {
    p=ui[u]
    who[u] = index(L[p],"〔等用户〕")>0 ? "用户" : (index(L[p],"〔等外部〕")>0 ? "外部" : "会话")
    b=0
    for (q=1;q<=cm[u];q++) if (cl[u,q] ~ /^[ \t]*- \[ \][ \t]/ && index(cl[u,q],"阻塞:")>0) b++
    blkn[u]=b
    mx=(p in ts)?ts[p]:0
    for (j=p+1;j<=N;j++) {
      if (L[j] ~ /^- \[[ xX]\][ \t]/ || L[j] ~ /^#/) break
      if ((j in ts) && ts[j]>mx) mx=ts[j]
    }
    lastts[u]=mx
    dq = getdate(substr(L[p],1,240))
    if (dq!="" && dq!="排期") { split(dq,aq,"-"); age[u]=dfc(TY+0,TM+0,TD+0)-dfc(aq[1]+0,aq[2]+0,aq[3]+0); regdate[u]=aq[1]"-"aq[2]"-"aq[3] }
    else { age[u]=-1; regdate[u]="" }
  }

  cap = CAP+0
  z0=0; for (u=1;u<=un;u++) if (cm[u]==0) z0++
  hoist = (z0>=10 && z0*100 >= 70*un)

  hdr = PROJ " 进度"
  if (BASE!="") hdr = hdr "    本会话基线 " BASE; else hdr = hdr "    (未给 --base,不标 \342\230\205)"
  print hdr
  if (cap>0 && un>cap) print "   (打了 " cap " 条 / 未完共 " un " 条,按登记日期最老优先;全量看 task_plan.md)"
  if (hoist) print "   (本仓 " z0 " 条大活底下没登记子任务,行尾不再逐条打)"
  print "\342\224\202"

  if (cap > 0 && un > cap) {
    for (u=1;u<=un;u++) {
      dk = getdate(substr(L[ui[u]],1,240))
      kk[u] = (dk=="" ? "9999-99-99" : (dk=="\346\216\222\346\234\237" ? "9999-99-98" : dk))
    }
    nsel=0
    while (nsel < cap && nsel < un) {
      best=0
      for (u=1;u<=un;u++) { if (u in taken) continue; if (best==0 || kk[u] < kk[best]) best=u }
      if (best==0) break
      taken[best]=1; ord[++nsel]=best
    }
  } else { nsel=un; for (u=1;u<=un;u++) ord[u]=u }

  for (z=1;z<=nsel;z++) {
    u=ord[z]; p=ui[u]; m=cm[u]
    if (ALL+0 && z>1 && (m>0 || cm[ord[z-1]]>0)) print "\342\224\202"
    last = (z==nsel)
    conn = last ? "\342\224\224\342\224\200 " : "\342\224\234\342\224\200 "
    base = last ? "   " : "\342\224\202  "

    t = title(L[p]); dt = getdate(substr(L[p],1,240))
    s = stat(L[p]); k = key(L[p]); tail = ""
    if (k in star) { s = s "\342\230\205"; tail = "  \342\206\220 本会话" }
    else if (k in nblk) { s = s "\342\230\205"; tail = "  \342\206\220 本会话新增" }

    line = conn s " " wrap(t)
    if (m>0) {
      dn=0; tt=0
      for(q=1;q<=m;q++) if (cd[u,q]==1) { tt++; if (cl[u,q] ~ /^[ \t]*- \[[xX]\]/) dn++ }
      if (tt>0) line = line " (" dn "/" tt ")"
    }
    if (dt!="" && dt!="排期") {
      split(dt,a,"-"); days = dfc(TY+0,TM+0,TD+0) - dfc(a[1]+0,a[2]+0,a[3]+0)
      line = line " \302\267 " a[1] "-" a[2] "-" a[3] " 登记"
      if (days>=0) line = line " \302\267 挂了 " days " 天"
    }
    if (m==0 && !hoist) line = line " \302\267 子任务盘上无结构"   # hoist=1 时这句已在树头说过一次
    if (blkn[u]>0) line = line " \342\232\240\345\215\241" blkn[u]
    if (who[u]!="会话") line = line " \302\267 等" who[u]
    print line tail

    if (!(ALL+0)) continue        # 折叠版:子项行一行不打
    for (q=1;q<=m;q++) {
      d = cd[u,q]
      lastq=1
      for (r=q+1;r<=m;r++) { if (cd[u,r]<d) break; if (cd[u,r]==d) { lastq=0; break } }
      pre = base
      for (lv=1; lv<d; lv++) {                    # 祖先层:最近一个同层节点是不是它那层的最后一个
        anc=0
        for (r=q-1;r>=1;r--) if (cd[u,r]==lv) { anc=r; break }
        al=1
        if (anc>0) for (r=anc+1;r<=m;r++) { if (cd[u,r]<lv) break; if (cd[u,r]==lv) { al=0; break } }
        pre = pre (al ? "   " : "\342\224\202  ")
      }
      cs = stat(cl[u,q]); ck = key(cl[u,q]); ctail=""
      if (ck in star) { cs = cs "\342\230\205"; ctail = "  \342\206\220 本会话" }
      else if (ck in nblk) { cs = cs "\342\230\205"; ctail = "  \342\206\220 本会话新增" }
      print pre (lastq ? "\342\224\224\342\224\200 " : "\342\224\234\342\224\200 ") cs " " wrap(name(cl[u,q])) ctail
    }
  }

  if (!(ALL+0)) exit        # 折叠版不打:不给 --全 时通常也没 --base,五段里三段是「待人工填」
  print ""
  print "\342\224\201\342\224\201\342\224\201\342\224\201\342\224\201 本会话完成 \342\224\201\342\224\201\342\224\201\342\224\201\342\224\201"
  if (BASE=="") print "(未给 --base,本会话完成机械上判不出来——不猜)"
  else {
    n1=0
    for (i=1;i<=N;i++) if (L[i] ~ /^[ \t]*- \[[ xX]\][ \t]/ && (key(L[i]) in star)) { print "\342\230\205 " wrap(name(L[i])); n1++ }
    if (n1==0) print "暂无"
  }
  print ""
  if (BASE=="") print "本会话新增阻塞:(未给 --base,判不出来)"
  else {
    n2=0
    for (i=1;i<=N;i++) if (L[i] ~ /^[ \t]*- \[ \][ \t]/ && (key(L[i]) in nblk)) n2++
    if (n2==0) print "本会话新增阻塞:暂无"
    else {
      print "本会话新增阻塞(" n2 " 条" (n2>8 ? ",下列 8 条" : "") "):"
      k=0
      for (i=1;i<=N;i++) if (L[i] ~ /^[ \t]*- \[ \][ \t]/ && (key(L[i]) in nblk)) {
        if (++k>8) break
        print "  \342\232\240 " wrap(name(L[i]))
      }
      if (n2>8) print "  (另有 " n2-8 " 条,全量看 task_plan.md 里带「阻塞:」的行)"
    }
  }
  first=0
  for (u=1;u<=un;u++) {
    if (who[u]!="会话") continue
    if (first==0) { first=u; continue }
    if (blkn[u]!=blkn[first]) { if (blkn[u]<blkn[first]) first=u; continue }
    if (lastts[u]!=lastts[first]) {
      if (lastts[first]==0) first=u                                   # 现任是「取不到」,有值的顶掉它
      else if (lastts[u]!=0 && lastts[u]<lastts[first]) first=u       # 0 是「不知道」,不是「很久以前」
      continue
    }
    if (age[u]>age[first]) first=u
  }
  nuser=0; nout=0; nblkall=0
  for (u=1;u<=un;u++) { nblkall+=blkn[u]; if (who[u]=="用户") nuser++; if (who[u]=="外部") nout++ }

  if (first==0) {
    print "当前正在处理:没有一件是我这边能推的 \342\200\224\342\200\224 " un " 条未完大活全标着在等人"
    print "为什么是它:(挑不出来。先把下面「等你拍板」那几条给用户,或者去掉某条的〔等…〕标记)"
    print "下一步:(同上)"
  } else {
    print "当前正在处理:" wrap(title(L[ui[first]])) "  \342\206\220 今天先做这一件"
    r = "我这边能推(没在等人)"
    r = r " \302\267 " (blkn[first]==0 ? "没有卡点" : blkn[first] " 个卡点(同批里最少)")
    dd = lastts[first]>0 ? TODAYN - lastts[first] : -1
    if (dd<0)       r = r " \302\267 上次动过取不到(blame 没抓着)"
    else if (dd==0) r = r " \302\267 今天动过"
    else            r = r " \302\267 上次动过 " dd " 天前"
    if (age[first]>=0) r = r " \302\267 挂了 " age[first] " 天 \302\267 " regdate[first] " 登记"
    print "为什么是它:" r
    nx=""
    for (q=1;q<=cm[first];q++) if (cl[first,q] ~ /^[ \t]*- \[ \][ \t]/) { nx=name(cl[first,q]); break }
    print "下一步:" (nx=="" ? "这条底下盘上没登记子任务,第一步是先把它拆成小步" : wrap(nx))
  }
  if (nblkall==0 && nuser==0 && nout==0) print "阻塞项:暂无"
  else {
    print "阻塞项:" nblkall " 个卡点 \302\267 " nuser " 条在等用户 \302\267 " nout " 条在等外部"
    k=0
    for (u=1;u<=un;u++) if (who[u]=="用户") { if (++k>5) break; print "  \342\232\240 等你拍板:" wrap(title(L[ui[u]])) }
    if (nuser>5) print "  (另有 " nuser-5 " 条在等你,全量看 task_plan.md 里带〔等用户〕的行)"
  }
}
' "$TS" "$DF" "$PLAN" | sed -E 's/\x01(.{40})[^\x02]*\x02/\1…/g; s/\x01//g; s/\x02//g' \
  | awk '{ if (gsub(/`/,"`") % 2) { for(i=length($0);i>0;i--) if(substr($0,i,1)=="`") { $0=substr($0,1,i-1) substr($0,i+1); break } } print }'
尾部
}

FENCE='```'
if [ -n "$FENCE" ]; then printf '%s\n' "$FENCE"; fi
if [ -n "$OUT" ]; then
  T="$OUT.tmp.$$"
  render > "$T" || { rm -f "$T"; exit 1; }
  mv -f "$T" "$OUT"
  cat "$OUT"
else
  render
fi
if [ -n "$FENCE" ]; then printf '%s\n' "$FENCE"; fi
exit 0
