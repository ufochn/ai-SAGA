# AI-SAGA Dify 小说工作流：提示词与节点设计模版

> 目标：Dify 大模型模块生成小说 —— **先流式输出纯小说正文**，正文流结束后**再输出几个结构化变量**给服务器端（经 `workflow_finished.outputs` 转交 Flutter）。
>
> 适用：Dify「工作流」应用，手动在画布搭建（不要依赖 LLM 生成的 DSL，见 README 警告）。

---

## 0. 先讲清楚一个硬约束（决定架构）

当前服务端 [`server/main.py`](server/main.py:1485) 的处理方式：

- LLM 节点的 `text` 输出会被 Dify 拆成一条条 `text_chunk` **流式**发给服务器；
- 服务器把所有 `text_chunk` 累加成 `full_text`，并把 `outputs.get("text")` 当作**最终小说全文**（用于二次审核 + 落库 `story_segments.content`）；
- `workflow_finished` 事件里的 **`outputs` 整体**会被服务器原样转发到 Flutter 的 `reveal` / `done` 事件（[`story_service.dart`](lib/logic/story_service.dart:142)）。

结论：**不能在 LLM 的 `text` 末尾拼一段 JSON 变量** —— 那串 JSON 会：
1. 被当作小说正文流式打出来（污染打字机）；
2. 被持久化进小说正文（污染落库）；
3. 可能把首段 450 字审核一起带偏。

所以"先正文、后变量"必须拆成两个输出通道：

| 内容 | 来源 | 到达时机 |
|---|---|---|
| 小说正文（纯文本） | **LLM#1** 的 `text` 输出 | `text_chunk` **流式**到达（先） |
| 后续变量（结构化） | **LLM#2 / Code** → **End 节点其它 outputs** | `workflow_finished` 一次性到达（后） |

---

## 1. 推荐画布架构

```
Start(接收全部变量 + previous_story + max_tokens)
  └─> Code①「清洗用户设置」→ clean_prompt(JSON 字符串)
       └─> LLM①「小说正文生成」→ text(纯文本，流式)
            └─> LLM②「剧情元数据生成」→ meta_json(严格 JSON)
                 └─> Code②「解析元数据 JSON」→ title / summary / choice_1/2/3
                      └─> End
                           ├─ text      ← LLM①.text   （服务器当小说全文用）
                           ├─ title     ← Code②
                           ├─ summary   ← Code②
                           ├─ choice_1  ← Code②
                           ├─ choice_2  ← Code②
                           └─ choice_3  ← Code②
```

要点：
- **LLM② 必须串在 LLM① 之后**（输入引用 LLM① 的 `text`），这样它只有在正文完整生成后才运行，变量天然"在流式结束后"才可用 → 全部进 `workflow_finished.outputs`，完全符合现有服务端逻辑。
- **End 节点必须暴露 `text` = LLM①.text**。服务端 `outputs.get("text")` 是权威正文来源，缺了它就走兜底、可能拿不全。

---

## 2. Start 节点变量清单

在现有变量（location / era / player_name / player_gender / partner_name / partner_gender / partner_traits / language / user_input / user_input_counter）之外，**必须新增**（服务端已经按这些名字发送，见 [`server/main.py`](server/main.py:1420)）：

| variable | 类型 | 说明 |
|---|---|---|
| `previous_story` | text-input | 上一段剧情（空则全新故事） |
| `max_tokens` | number 或 text-input | 输出长度上限（服务端下发 DIFY_MAX_TOKENS） |

---

## 3. LLM① 小说正文生成 —— 系统提示词模版

> 作用：只产出**纯正文**，严格流式，正文后什么都不追加。

```
你是 AI-SAGA 互动小说生成引擎。请严格依据用户的设定与剧情上下文，撰写【下一段】小说正文。

【用户设定】(JSON)
{{#<Code①节点id>.clean_prompt#}}

【上一段剧情】(若为空字符串，则为全新故事的开篇)
{{#<Start节点id>.previous_story#}}

【本轮用户输入】
{{#<Start节点id>.user_input#}}
（这是第 {{#<Start节点id>.user_input_counter#}} 轮输入）

【输出要求 —— 必须严格遵守】
1. 只输出小说正文本身：从正文第一个字开始写，不要任何开场白、说明或前缀。
2. 严禁输出 JSON、代码块、Markdown、标题、序号、注释或任何解释性文字。
3. 严禁在正文末尾追加任何变量、分隔符、标签或结构信息——正文到此为止，什么都不加。
4. 正文须与「上一段剧情」自然衔接（若存在），并围绕「本轮用户输入」推进剧情。
5. 篇幅控制在 {{#<Start节点id>.max_tokens#}} token 以内，内容充实、有画面感。
6. 全程使用「用户设定」中 language 字段指定的语言撰写。
```

---

## 4. LLM② 剧情元数据生成 —— 系统提示词模版

> 作用：在收到完整正文后，**只**输出一个严格 JSON，供下一轮互动使用。变量名可按需增删，但必须与 End 节点映射一致。

```
你是 AI-SAGA 剧情元数据引擎。收到【完整的小说正文】后，只输出一个 JSON 对象，为下一轮互动提供变量。

【完整小说正文】
{{#<LLM①节点id>.text#}}

【输出要求 —— 必须严格遵守】
1. 只输出一个 JSON 对象：不要输出任何其它文字、解释、Markdown 代码块或注释。
2. 字段名不可更改，结构如下：
{
  "title": "本段标题（一句话，10 字以内）",
  "summary": "本段剧情摘要（40 字以内）",
  "choice_1": "下一轮行动选项一（一句话）",
  "choice_2": "下一轮行动选项二（一句话）",
  "choice_3": "下一轮行动选项三（一句话）"
}
3. choice_1/2/3 必须互不重复、与刚生成的剧情直接相关、情节上合理且可执行。
4. 所有字符串字段不得包含换行符。
```

---

## 5. Code② 解析元数据 JSON —— Python 代码

> 作用：把 LLM② 的输出（可能带 ```json 包裹、前后空行）稳健地解析成干净字段，避免一个坏 JSON 拖垮整个工作流。

```python
import json

def main(meta_json: str) -> dict:
    text = (meta_json or "").strip()
    # 去掉 ```json ... ``` 包裹
    if text.startswith("```"):
        text = text.strip("`").strip()
        if text.startswith("json"):
            text = text[4:].strip()
    # 只截取第一个 { 到最后一个 } 之间的部分
    s, e = text.find("{"), text.rfind("}")
    data = {}
    if s != -1 and e > s:
        try:
            data = json.loads(text[s:e + 1])
        except Exception:
            data = {}
    if not isinstance(data, dict):
        data = {}

    def g(key: str) -> str:
        v = data.get(key)
        if isinstance(v, str):
            return v.strip()
        if v is None:
            return ""
        return str(v)

    return {
        "title": g("title"),
        "summary": g("summary"),
        "choice_1": g("choice_1"),
        "choice_2": g("choice_2"),
        "choice_3": g("choice_3"),
    }
```

- 输入：`meta_json`（string）← LLM② 的 `text`
- 输出：`title` / `summary` / `choice_1` / `choice_2` / `choice_3`，全部声明为 **string**（声明方式与现有 [`ai_saga_fiction_workflow.yml`](ai_saga_fiction_workflow.yml:277) 的 `outputs` 一致：`{变量名: {description: '', type: string}}`）。

---

## 6. End 节点输出配置

| variable | value_selector | value_type |
|---|---|---|
| `text` | LLM① → `text` | string |
| `title` | Code② → `title` | string |
| `summary` | Code② → `summary` | string |
| `choice_1` | Code② → `choice_1` | string |
| `choice_2` | Code② → `choice_2` | string |
| `choice_3` | Code② → `choice_3` | string |

> `text` 务必是 LLM① 的 `text`（不是 Code② 的任何字段），否则正文会被替换成元数据。

---

## 7. 验证清单（画布发布前逐项核对）

- [ ] `response_mode` 为 `streaming`（服务端已固定，见 [`server/main.py`](server/main.py:1438)）。
- [ ] LLM① 系统提示词里的变量引用都是用 Dify 编辑器"插入变量 {}"按钮插入的（**不要手敲 `{{#...}}`**，否则会存成字面文本，见 README 警告）。
- [ ] LLM① 只绑 `clean_prompt / previous_story / user_input / user_input_counter / max_tokens`，绝不把元数据指令塞进正文提示词。
- [ ] LLM② 串在 LLM① 之后，输入引用 LLM① 的 `text`。
- [ ] Code② 的 `outputs` 是 dict：`{name: {description, type: string}}`，不是 list。
- [ ] End 输出含 `text` 且指向 LLM①。
- [ ] 在 Dify 控制台**发布**工作流后再调用（未发布 → "Workflow not published"）。

---

## 8. 变量名若需调整

- 若你想输出的"后续变量"不是上面这几个，改三处即可，保持一致：
  1. LLM② 提示词里的 JSON 结构；
  2. Code② `main()` 里 `g("...")` 的键名与返回值；
  3. End 节点映射的变量名。
- 服务端无需改动：`outputs` 里所有键都会原样转发给 Flutter（[`server/main.py`](server/main.py:1485) → [`story_service.dart`](lib/logic/story_service.dart:142)）。
