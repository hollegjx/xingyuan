# v2 后端部署准备（C79，2026-11-02）

**这是待执行材料，不是部署记录。** AI-2 未连接服务器、读凭据、部署、访问线上 health 或调用真实模型。执行人由所有者指定后再使用以下命令；本文不授予 AI-2 这些权限。沿用 [发布方式](backend-migration.md)，只准备/切换星愿 release 和重启 `xingyuan-assistant`，不改 `/etc/xingyuan`、unit、Caddy、DNS、模型或额度。

## 1. 固定版本和发布前条件

- 发布 **`be96fd17f7dec7ad41786e8d44979de2c6952d75`**；它是已独立复核并安装 B 的代码提交。本文后续文档提交不是发布目标，不使用浮动 HEAD。
- 回滚 **`a88a53e92766a9f022a69e2b389b1167c519d5af`**。实际 `current` 若不是此 release，或旧 release 不存在，停止并交统筹重新确定回滚基线，不猜路径、不覆盖已有目录。
- 已有独立 QA：App 最终覆盖 2042 项（原全量 1 次超时与补验分列）、server 467 / core 133 / eval 189、四分析/格式。见 `.ai-bus/review/AI-1/C78-independent/report.md`；原隐私失败与超时保留。本轮不重复已完成 gate。
- Debian 12 x86_64 历史基线需执行者当场确认。构建固定使用已有 `/opt/xingyuan/toolchains/3.13.5/dart-sdk/bin/dart`；仓库 SDK 约束 `^3.13.5`，本材料只支持已验证 3.13.5，不以“范围内版本”代替证据。
- 依赖：已有 `xingyuan`、`xingyuan-build` 用户；Bash、GNU coreutils/tar、curl、Python 3、systemd、Linux 原生构建所需工具，以及可获取锁定依赖的构建缓存/网络。`pub get --enforce-lockfile` 失败即停，不改锁文件或安装全局工具链。新系统依赖或权限变更交所有者，不通过本脚本补装。
- SQLite 3.5.2 带 native assets，必须保留三套完整 `build/{server,devices,backup}/bundle/{bin,lib}`。不得把 Mac 二进制放到 Linux，也不得只复制 `bin/server`。当前模板的 `ExecStart` 必须已指向 `current/server/build/server/bundle/bin/server`。
- 执行者先确认既有一致备份可读、存储空间足够、既有数据目录和 ledger 可写；不能把复制运行中 SQLite 主文件当一致备份。按原运维流程处理，本文不恢复/删除任何业务数据、照片、设备登记或配额。
- 重启会中止进程内 Agent run，旧 run 续传可能得到 `run_restart_required`；选择空闲窗口并记录，不把跨重启续跑当保证。客户端应重新发起新 run。账本 schema 仍为 1，新增 App schema14 **不是**服务端库迁移；回滚不恢复配额库或业务库。

### 配置/环境变化核对

对比 a88a53e：`server/bin/server.dart`、`model_config.dart`、server pubspec/lock、core pubspec、systemd 模板均逐字节相同；本地证据 `.ai-bus/review/AI-2/C79-deploy-prep/source-evidence.json`。

| 项目 | 要求 |
| --- | --- |
| 新增应用环境变量 | **无**。下文 `V2_*` 仅为执行脚本参数，不写入服务环境 |
| 新增配置字段/秘密/依赖 | **无**；模型、reasoning、token 限额、设备注册表保持 |
| `agent_ledger_database` | 既有配置项，必须已有有效绝对路径、原账本及运行用户访问权限；缺省会使 v1/v2 Agent 和能力探测返回 503。若线上缺失，**停止，作为 `/etc/xingyuan` 配置变更另请所有者决定**，不在本次补值 |
| `companion_database` / `companion_objects` | 原路径、数据及权限不变；不初始化替代库 |
| 配置核对方式 | 执行者按已有私有运维记录确认字段存在/权限，不把 JSON、密钥或 token 打印/复制进报告 |

### v1 兼容证据与限制

1. 正式版 `86b48ad` 使用旧 assistant v1；新增 `diary_proposals` 是可选字段，缺省 false，旧请求不强加日记字段。a88a53e 到本候选的 `protocol.dart` 完全相同，旧 assistant 解析/响应行为未改变。
2. B 旧 Agent 客户端继续 `/v1/agent/turn` 和五工具。`agent_contract.dart` 与 a88a53e 的 blob 同为 `0ba93a22698a941b809e0b551d59078d424e97ff`；旧 v1/v2/v3 提示词不变，只有独立 v2 路由使用 agent-v4。
3. 独立 server/core 全量含旧路由/鉴权/协议边界（`server/test/service_test.dart`、`agent_service_test.dart`、`packages/xingyuan_core/test/protocol_test.dart`）；`assistant_agent_v2_test.dart` 覆盖 v2 八工具、v1 拒绝新工具、协议错路拒绝、不能跨版本续跑。AI-1 另外实测当前 App → 本机真实 a88a53e 服务回退（假模型）。这是反向回退证据，不能替代旧手机 → 新服务实机验证。
4. 没有宣称正式版86b48ad或旧B本轮真机回归已完成。发布后先做下面的零模型路由检查，再按单次额度做合成 Agent 回合；模型语义质量、原生助手页及新工具端到端交付另列。

## 2. 本机只导出已复核源码

以下在持有仓库的本机运行，只写新建临时目录；**不要从脏工作树打包**。按现有已核对主机指纹的安全通道由指定执行者传输压缩包与校验文件，本材料不内置 SSH 凭据/地址，也不执行传输。

```bash
set -euo pipefail
umask 077
V2_RELEASE=be96fd17f7dec7ad41786e8d44979de2c6952d75
V2_EXPORT=$(mktemp -d "${TMPDIR:-/tmp}/xingyuan-v2-source.XXXXXX")
git cat-file -e "$V2_RELEASE^{commit}"
git archive --format=tar.gz --output="$V2_EXPORT/source.tar.gz" "$V2_RELEASE" server packages/xingyuan_core
(cd "$V2_EXPORT" && shasum -a 256 source.tar.gz > source.sha256)
printf 'Source package: %s\n' "$V2_EXPORT"
```

## 3. 指定执行者：服务器准备与构建（此处才开始远端操作）

以下块在已授权服务器的 root Bash 中执行。先把上述两个文件放进一个新的私有接收目录，用真实绝对路径设置 `V2_INBOX`。所有步骤必须顺序成功；失败保持旧 current，不重跑已创建 release，不删除失败材料，由统筹决定新批次。

```bash
set -euo pipefail
umask 077
export V2_RELEASE=be96fd17f7dec7ad41786e8d44979de2c6952d75
export V2_OLD=a88a53e92766a9f022a69e2b389b1167c519d5af
export V2_DIR="/opt/xingyuan/releases/$V2_RELEASE"
export V2_DART=/opt/xingyuan/toolchains/3.13.5/dart-sdk/bin/dart
: "${V2_INBOX:?Set V2_INBOX to the private received-package directory}"
test "$(id -u)" = 0
test "$(uname -m)" = x86_64
test "$(. /etc/os-release; printf '%s:%s' "$ID" "$VERSION_ID")" = debian:12
test "$(readlink -f /opt/xingyuan/current)" = "/opt/xingyuan/releases/$V2_OLD"
test -x "/opt/xingyuan/releases/$V2_OLD/server/build/server/bundle/bin/server"
test -x "$V2_DART"
"$V2_DART" --version 2>&1 | grep -F 'Dart SDK version: 3.13.5 '
getent passwd xingyuan >/dev/null
getent passwd xingyuan-build >/dev/null
systemctl is-active --quiet xingyuan-assistant
systemctl show xingyuan-assistant -p ExecStart --value | grep -F '/opt/xingyuan/current/server/build/server/bundle/bin/server --config /etc/xingyuan/assistant-server.json'
(cd "$V2_INBOX" && sha256sum --check source.sha256)
test ! -e "$V2_DIR"
install -d -m 0755 -o xingyuan-build -g xingyuan-build "$V2_DIR"
tar -xzf "$V2_INBOX/source.tar.gz" -C "$V2_DIR" --no-same-owner
chown -R xingyuan-build:xingyuan-build "$V2_DIR"
# 私有新构建缓存，不替换现有全局缓存/运行环境。
export V2_CACHE="$V2_DIR/.pub-cache"
install -d -m 0700 -o xingyuan-build -g xingyuan-build "$V2_CACHE"
runuser -u xingyuan-build -- env PUB_CACHE="$V2_CACHE" V2_DIR="$V2_DIR" V2_DART="$V2_DART" bash -euo pipefail -c '
  cd "$V2_DIR/server"
  "$V2_DART" pub get --enforce-lockfile
  "$V2_DART" build cli --target=bin/server.dart --output=build/server
  "$V2_DART" build cli --target=bin/devices.dart --output=build/devices
  "$V2_DART" build cli --target=bin/backup.dart --output=build/backup
'
for V2_APP in server devices backup; do
  test -x "$V2_DIR/server/build/$V2_APP/bundle/bin/$V2_APP"
  test -d "$V2_DIR/server/build/$V2_APP/bundle/lib"
done
# 发布源码/产物不含秘密；运行用户只读，业务写入仍在原数据目录。
chown -R root:root "$V2_DIR"
chmod -R u+rwX,go+rX,go-w "$V2_DIR"
runuser -u xingyuan -- test -x "$V2_DIR/server/build/server/bundle/bin/server"
printf '%s\n' "$V2_RELEASE" > "$V2_DIR/RELEASE_COMMIT"
(cd "$V2_DIR" && find server/build -type f -print0 | sort -z | xargs -0 sha256sum > BUILD_SHA256SUMS)
```

也可由兼容 Linux 构建机交完整三套 bundle；须附上述精确提交、Dart版本、OS/架构、文件 SHA-256 清单并逐项核对，仍用不存在的新 release。不能因为复制成功就省略启动/能力检查。不得为构建使用 `dart run bin/server.dart --config ...` 提前连真实模型或并开生产库。

## 4. 原子切换、健康检查与一条命令回滚

仍在同一服务器 root Bash；先完成配置存在性/备份/运行时核对。不要复制 unit 或执行 daemon-reload，不动备份 timer。

```bash
set -euo pipefail
: "${V2_DIR:?Complete step 3 first}"
: "${V2_OLD:?Complete step 3 first}"
test "$(readlink -f /opt/xingyuan/current)" = "/opt/xingyuan/releases/$V2_OLD"
test "$(cat "$V2_DIR/RELEASE_COMMIT")" = be96fd17f7dec7ad41786e8d44979de2c6952d75
(cd "$V2_DIR" && sha256sum --check BUILD_SHA256SUMS >/dev/null)
V2_LINK="/opt/xingyuan/.current-v2-$$"
test ! -e "$V2_LINK"
ln -s "$V2_DIR" "$V2_LINK"
mv -Tf "$V2_LINK" /opt/xingyuan/current
systemctl restart xingyuan-assistant
systemctl is-active --quiet xingyuan-assistant
curl --fail --silent --show-error --connect-timeout 5 --max-time 10 https://assistant.example.com/v1/health | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"protocol":"xingyuan.assistant.v1","status":"ok"}; print("health: ok")'
```

任何启动/健康失败立即执行下面**一条命令**回滚，之后复核旧 current、service active 和 HTTPS health。不等待15分钟，不恢复旧数据库或注册表，不删除失败 release。此命令只适用于前面确认过的 a88a53e bundle 和原 unit 路径：

```bash
bash -euc 'v2_old=/opt/xingyuan/releases/a88a53e92766a9f022a69e2b389b1167c519d5af; test -x "$v2_old/server/build/server/bundle/bin/server"; v2_link=/opt/xingyuan/.rollback-v2-$$; test ! -e "$v2_link"; ln -s "$v2_old" "$v2_link"; mv -Tf "$v2_link" /opt/xingyuan/current; systemctl restart xingyuan-assistant; systemctl is-active --quiet xingyuan-assistant'
```

回滚不自动恢复进行中的 run；v2 客户端下次能力探测应回退v1。不得为让新工具继续运行而偷偷改配置。回滚后重发健康 GET，记录失败点、回滚时间、旧版本和健康结果，不附任何秘密/正文。

## 5. 发布后冒烟：零模型检查 + 最多3次合成 Agent 请求

由被授权执行者在已有 Python 3.9+ 的受信机器运行，网络目标固定 `https://assistant.example.com`。使用已有、明确获准的 QA 设备 token 文件（0600，仓库外），**不读手机私有记录、不新签/改写注册表**。下面仅设置路径；token只在内存中读，不放argv/环境值/日志。没有获准凭据则先停，不用匿名401代替成功鉴权。

将下面 Python 块保存为私有目录的 `v2-smoke.py`（0600）。先运行 `python3 /private/path/v2-smoke.py`，只检查health、能力探测与旧路由的鉴权/结构拒绝，模型调用0。能力探测是**无正文 GET**，必须200、protocol=v2且8工具；503/404都不能当成功。对旧路由发送空对象的预期400仅证明鉴权后路由和解析存在，不证明真实模型业务通过。

经执行者取得真实模型额度授权后，才运行 `python3 /private/path/v2-smoke.py --live`：v2首轮索取summary（最多1次模型）→回传合成summary（最多1次模型）→v1五工具协议简单回合（最多1次模型），合计**最多3次**，无重试。v2第二轮若返回下一个工具，只验证接收并停止，不执行该工具；不把它当完整日记或语义验收。任何意外即失败退出，已花调用仍计入上限；不再次运行脚本凑成功。

```bash
export V2_TOKEN_FILE=/private/path/existing-authorized-qa-token
export V2_SMOKE_MARKER=/private/path/v2-live-attempted-be96fd17
```

```python
import datetime, http.client, json, os, pathlib, stat, sys, uuid
from zoneinfo import ZoneInfo

def require(ok, message):
    if not ok:
        raise SystemExit(message)

require(sys.argv[1:] in ([], ['--live']), 'usage: v2-smoke.py [--live]')
credential = pathlib.Path(os.environ['V2_TOKEN_FILE'])
mode = credential.stat().st_mode
require(stat.S_ISREG(mode) and mode & 0o077 == 0, 'private token file required')
token = credential.read_text().strip()
require(bool(token) and '\n' not in token and '\r' not in token, 'invalid token file')
model_attempts = 0

def send(path, body=None, auth=True):
    headers = {'Accept': 'application/json'}
    if auth:
        headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    conn = http.client.HTTPSConnection('assistant.example.com', timeout=70)
    try:
        conn.request('GET' if data is None else 'POST', path, body=data, headers=headers)
        response = conn.getresponse()
        payload = response.read(65537)
        require(len(payload) <= 65536, 'oversized response')
        require(response.status < 300 or response.status >= 400, 'redirect rejected')
        parsed = json.loads(payload)
        print(json.dumps({'route': path, 'status': response.status}))
        return response.status, parsed
    except (OSError, ValueError, http.client.HTTPException):
        raise SystemExit('transport/JSON failed; no retry; retain attempt count')
    finally:
        conn.close()

status, body = send('/v1/health', auth=False)
require(status == 200 and body == {'protocol': 'xingyuan.assistant.v1', 'status': 'ok'}, 'health failed')
status, body = send('/v2/agent/capabilities')
v1_tools = {'get_planning_preferences', 'query_schedule', 'find_free_slots', 'validate_plan', 'submit_plan_draft'}
require(status == 200 and body.get('protocol') == 'xingyuan.agent.v2' and
        len(body.get('tools', [])) == 8 and set(body['tools']) ==
        v1_tools | {'get_day_summary', 'get_journal_text', 'create_diary_draft'}, 'capability failed')
require(send('/v2/agent/capabilities', auth=False)[0] == 401, 'missing auth not rejected')
for route in ('turn', 'summarize', 'analyze-day', 'polish-note', 'generate-diary', 'agent/turn'):
    status, body = send('/v1/' + route, {})
    require(status == 400 and body.get('error') == 'invalid_request', 'v1 structural rejection changed')
if '--live' not in sys.argv:
    print('zero-model checks passed; no business/semantic claim')
    raise SystemExit(0)

# Exclusive marker prevents accidental repeat; do not remove it to retry.
marker = pathlib.Path(os.environ['V2_SMOKE_MARKER'])
fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as receipt:
    receipt.write('live attempted; maximum 3 requests; never auto-retry\n')
now = datetime.datetime.now(ZoneInfo('Asia/Shanghai'))
clock = {'date': now.strftime('%Y-%m-%d'), 'time': now.strftime('%H:%M'),
         'weekday': now.isoweekday(), 'time_zone': 'Asia/Shanghai'}

def turn(path, request):
    global model_attempts
    require(model_attempts < 3, 'model call ceiling reached')
    model_attempts += 1  # Count even failed/uncertain HTTP delivery; never retry.
    print(json.dumps({'model_request_attempt': model_attempts}))
    status, reply = send(path, request)
    require(status == 200 and reply.get('protocol') == request['protocol'] and
            reply.get('request_id') == request['request_id'] and
            reply.get('turn') == request['turn'] and isinstance(reply.get('run_id'), str), 'turn correlation failed')
    require(reply.get('kind') in ('text', 'question', 'tool_call') and
            reply.get('budget', {}).get('violation') is False, 'turn stopped or budget failed')
    return reply

request = {'protocol': 'xingyuan.agent.v2', 'request_id': 'v2-smoke-' + uuid.uuid4().hex,
           'run_id': None, 'turn': 1, 'now': clock, 'messages': [
               {'role': 'user', 'content': '测试：只调用get_day_summary读取今天' + clock['date'] +
                '的合成完成情况。得到结果后简单回应；不要读随手记、日记，不写草稿或任务。'}]}
first = turn('/v2/agent/turn', request)
call = first.get('tool_call', {})
require(first['kind'] == 'tool_call' and call.get('type') == 'function' and
        call.get('function', {}).get('name') == 'get_day_summary', 'expected summary tool; stop without retry')
require(json.loads(call['function']['arguments']) == {'day': clock['date']}, 'unexpected summary date')
result = {'status': 'ok', 'data': {'day': clock['date'], 'items': [
    {'title': 'TEST synthetic goal', 'planned_time': '09:00', 'planned_minutes': 10,
     'completed': True, 'completed_at': now.astimezone(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
     'text': 'TEST synthetic saved check-in'}]}}
request['run_id'] = first['run_id']
request['turn'] = 2
request['messages'] += [
    {'role': 'assistant', 'content': None, 'tool_calls': [call]},
    {'role': 'tool', 'tool_call_id': call['id'], 'content': json.dumps(result)}]
second = turn('/v2/agent/turn', request)
require(second['run_id'] == first['run_id'], 'continuation run mismatch')
# No third v2 tool execution and no local/remote record writes.
v1 = {'protocol': 'xingyuan.agent.v1', 'request_id': 'v1-smoke-' + uuid.uuid4().hex,
      'run_id': None, 'turn': 1, 'now': clock,
      'messages': [{'role': 'user', 'content': '测试：简单问候，不查询记录，不创建计划。'}]}
legacy = turn('/v1/agent/turn', v1)
if legacy['kind'] == 'tool_call':
    require(legacy['tool_call']['function']['name'] in v1_tools, 'v1 returned a v2 tool')
print(json.dumps({'synthetic_summary_roundtrip': True, 'v1_agent_accepted': True,
                  'model_request_attempts': model_attempts, 'semantic_quality_verified': False}))
```

Agent transport本身不重试；第三方中转内部行为不由脚本证明。不要运行旧 `deployed_probe.dart` 来替代上面限额：它可能增加其他真实模型请求。合成数据虽不含隐私，也不要把请求/模型回复正文或token贴到总线。发生401/429先停止调查凭据/配额，不发行新凭据、不改限额。

## 6. 观察15分钟与故障判定

冒烟结束后立即开始一个完整15分钟窗口（另保留切换到冒烟结束的日志；冒烟中6个空对象400与1个无凭据401是已知负控，必须单列）。下列命令只看星愿服务，不触碰中转或VPN；日志保存在执行者私有目录，不打印正文。`V2_OBSERVE_DIR` 必须是不存在的新绝对路径。

```bash
set -euo pipefail
: "${V2_OBSERVE_DIR:?Set a new private absolute report directory}"
test ! -e "$V2_OBSERVE_DIR"
install -d -m 0700 "$V2_OBSERVE_DIR"
V2_OBSERVE_START=$(date --iso-8601=seconds)
printf '%s\n' "$V2_OBSERVE_START" > "$V2_OBSERVE_DIR/start.txt"
systemctl show xingyuan-assistant -p NRestarts --value > "$V2_OBSERVE_DIR/restarts-before.txt"
# 另一终端可用同一命令 -f 跟踪到私有文件；不输出原始日志到共享聊天。
for V2_TICK in $(seq 1 60); do
  sleep 15
  systemctl is-active --quiet xingyuan-assistant
  journalctl -u xingyuan-assistant --since "$V2_OBSERVE_START" --no-pager -o cat > "$V2_OBSERVE_DIR/journal.txt"
  # 命中即停止观察，检查对应元数据并立即按第4节回滚；不要等满15分钟。
  if grep -Eq '"status"[[:space:]]*:[[:space:]]*5[0-9][0-9]|"status"[[:space:]]*:[[:space:]]*400|history_mismatch|invalid_request|invalid_model_output|service_error|agent_unavailable|model_timeout|model_connection|upstream_http|budget_violation"[[:space:]]*:[[:space:]]*true|Assistant server failed|Main process exited|Failed with result' "$V2_OBSERVE_DIR/journal.txt"; then
    printf '%s\n' 'Unexpected failure/protocol rejection: stop and roll back using step 4.' >&2
    exit 1
  fi
  systemctl show xingyuan-assistant -p NRestarts --value > "$V2_OBSERVE_DIR/restarts-current.txt"
  cmp "$V2_OBSERVE_DIR/restarts-before.txt" "$V2_OBSERVE_DIR/restarts-current.txt"
done
curl --fail --silent --show-error --connect-timeout 5 --max-time 10 https://assistant.example.com/v1/health | python3 -c 'import json,sys; assert json.load(sys.stdin)=={"protocol":"xingyuan.assistant.v1","status":"ok"}; print("15-minute health: ok")'
printf 'Observation completed at %s\n' "$(date --iso-8601=seconds)"
```

连续跟踪的具体命令为 `journalctl -u xingyuan-assistant --since "$V2_OBSERVE_START" -f -n 0 -o cat >> "$V2_OBSERVE_DIR/follow.txt"`，按满15分钟停止；它只辅助观察，不代替上面的状态/重启次数检查。关注 JSON `route/status/stop_code/kind/tool/round/budget_violation/retried`，不依赖 `grep error` 一词：很多协议失败是HTTP200的stopped，必须看stop_code。401/403/429、`run_restart_required`/`daily_quota`/`run_expired`需结合维护窗口和已知请求解释，未解释前不宣布上线成功；新5xx、协议拒绝或health失败按授权立即回滚。

执行报告只写精确版本、构建/切换/回滚时间、health与鉴权结论、实际模型尝试次数、15分钟窗口和异常统计、私有证据路径及待办。能力200或离线回退通过均不等于真机助手工具、日记保存或模型语义已验收。AI-2本次核验11个未变源码/配置基线、7个代码块语法，并在禁止网络的沙箱内用HTTP替身验证零模型、3次上限、错误工具停止、防重复标记4种路径；未读取真实凭据，不宣称远端步骤已经执行。证据在 `.ai-bus/review/AI-2/C79-deploy-prep/`。
