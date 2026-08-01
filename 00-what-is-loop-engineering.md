# ループエンジニアリング (Loop Engineering) 調査ノート

調査日: 2026-08-01

## 一行でいうと

**「AIにプロンプトを打つ人間」という役割から自分を外し、代わりにプロンプトを打つ仕組み（ループ）を設計すること。**

## 発端

2026年6〜7月にSNSでバズった。火をつけたのは主に3人:

| 人物 | 所属 | 発言 |
|---|---|---|
| **Boris Cherny** | Anthropic（Claude Code の作者） | 「私はもうClaudeにプロンプトを打っていない。ループが走っていて、そのループがClaudeにプロンプトを打ち、何をすべきか判断している。**私の仕事はループを書くことだ**」。2026年に自分では1行もコードを書かず、スマホから1日数十本のPRを承認するだけ、とのこと |
| **Peter Steinberger** | OpenAI（OpenClaw の作者） | 「もうコーディングエージェントにプロンプトを打つべきではない。**エージェントにプロンプトを打つループを設計すべきだ**」→ 24時間で500万ビュー |
| **Andrew Ng** | DeepLearning.AI | The Batch issue-359 (2026-06-26) で「"Loop engineering" is a hot buzzphrase」と受けて、自身の**3つのループ**を提示 |

補足: Google の **Addy Osmani** が構成要素を整理して広めた。

## Andrew Ng の3つのループ（0→1のプロダクト開発）

速い順に3層。内側ほど速く回り、外側ほど遅いが方向を決める。

### 1. Agentic Coding Loop（数分）
> "Given a product specification and optionally a set of evals (that is, a dataset against which to measure performance), we can have an AI agent write code, test its work, and keep iterating until the code is bug-free and meets its specification."

仕様 + evals を渡す → エージェントがコードを書く → 自分でテストする → 仕様を満たすまで回る。数分ごとに新しいバージョンがビルド・テストされる。

Ng 自身の例: 週末に娘のためのタイピング練習アプリを作っていたとき、コーディングエージェントは**約1時間、人間の介入なしで働き続けた**。途中で何度もWebブラウザを使って自分の作ったものを確認してから、報告してきたという。

> "This idea of closing the loop took off around the end of last year, and it has been a game changer in enabling coding agents to work longer productively without human intervention."

### 2. Developer Feedback Loop（数十分〜数時間）
人間が出来上がったものを見て、機能・UI・UXといった**より高いレイヤーの判断**をしてエージェントを方向づける。

Ng の指摘で重要なのは**人間の役割がシフトした**こと:

> "Last year, a lot of developers (including me) were acting as the QA (quality assurance) function for our coding agents, manually finding bugs and then asking the agent to fix them. But with coding agents much more able to test their own code, the amount of time we need to spend on this function has decreased significantly. This allows us to make higher-level product decisions."

つまり **人間がQA役をやめられた分が、そのままプロダクト判断に回った**。これがループエンジニアリングの実利。

**"taste" ではなく "context advantage"**:

> "Many people describe this human contribution as 'taste,' but I prefer to think of it as humans having a **context advantage**, since that gives us a clearer path to helping AI systems get better."
>
> "So long as the human knows something the AI does not, human-in-the-loop is needed to inject that knowledge into the system."

「センス」と呼ぶと属人的で終わるが、「文脈の優位」と捉えれば**AIに渡せば埋まる差**になる。だから human-in-the-loop が必要な理由も明確になる — 人間がAIの知らないことを知っている限りにおいて、である。

また Ng は、繰り返し同じ問題にぶつかるなら **evals を作れ** と言っている:

> "If you find that the system repeatedly runs into certain problems, building a set of evals for the agent becomes useful."

### 3. External Feedback Loop（数時間〜数日・数週間）
> "asking a few friends for feedback, launching to alpha testers, or putting the code into production with A/B testing."

友人のレビュー、アルファテスター、本番A/Bテスト。遅いが、**開発者のプロダクトビジョン**を形作り、それが1つ目のループに渡す仕様になる。

Ng の締めくくり — エンジニアの役割の拡張について:

> "With coding agents speeding up software development, more engineers are starting to play a partial product management role. For many engineers who are growing into this role, the hardest part is **shaping the product vision and striking a balance between building (bridging the gap between vision and spec) and getting user feedback to evolve the vision. It is important to do both!**"

作ることと、フィードバックを取ってビジョンを進化させること。**両方やれ**、というのが一番の実践的アドバイス。

```
[External Feedback] --(ビジョン)--> [Developer Feedback] --(仕様)--> [Agentic Coding]
       ^                                    ^                              |
       |                                    |                              |
       +--------- 動くもの -----------------+------- 動くもの -------------+
```

## 系譜: 何を設計対象にしてきたか

| 世代 | 名前 | 設計対象 |
|---|---|---|
| 2023〜 | プロンプトエンジニアリング | **1回の指示**の質 |
| 2025〜 | コンテキストエンジニアリング | AIに与える**情報**の設計 |
| 2025〜 | ハーネスエンジニアリング | エージェントの**道具と環境**一式 |
| 2026〜 | **ループエンジニアリング** | **指示を出し続けるシステム全体** |

置き換えではなく積み上げ。ループの中で回るのは依然としてプロンプトとコンテキストなので、下の層が雑だとループは増幅装置として働いて雑さを撒き散らす。

## ループの構成部品（Addy Osmani）

1. **スケジュール / 自動化** — 人手を介さずループを起動する（最も基盤）
2. **隔離された作業場所** — git worktree など。複数エージェントの成果物を互いから守る
3. **スキル** — プロジェクト知識をドキュメント化して毎回読ませる
4. **接続口（プラグイン/コネクタ/サブエージェント）** — DB や外部サービスへのアクセス
5. **検証の仕組み** — **作り手と検証役を分離する**
6. **外部メモリ** — 反復をまたいで記憶を保つ

## 重要な実践則

### ループの分割（作り手 ≠ 検証役）
コードを書くエージェントと検証するエージェントを分ける。自分の成果物の採点は甘くなるため。**これがループエンジニアリングの中で一番効く一手**とされている。

### 停止条件を設計する
「テストが通る」「lintが消える」「evalsのスコアが閾値を超える」など、**機械が判定できる終了条件**がないとループは回らない（または永遠に回る）。仕様と一緒に evals を渡せ、という Ng の指摘はここ。

### 起動頻度でコストを制御
Steinberger の例: 「Codexにリポジトリの保守管理を任せ、5分おきに起動して各スレッドに作業を割り当てる」。
ただしコストに直結するので、実務では1時間〜1日ごとが現実的。セカンドオピニオン（検証エージェント）も必要な箇所に限定する。

## 危険性・コスト

- **トークン消費**: エージェント1体で通常の約4倍、複数構成で約15倍。Steinberger は月130万ドル使った時期があると認めている
- **Osmani の警告**: 「**無人で走るループは、無人でミスをするループでもある**」
- ループが自動化されるほど、**システムの実態と人間の理解のギャップが広がる**。検証責任は人間に残り続ける

## 出典

- [Andrew Ng — The Batch issue-359 (2026-06-26)](https://www.deeplearning.ai/the-batch/issue-359/)
- [Andrew Ng の X 投稿](https://x.com/AndrewYNg/status/2071988145667928442)
- [ADTmag — Loop Engineering Emerges as Developers Put AI Coding Agents on Repeat](https://adtmag.com/articles/2026/07/01/loop-engineering-emerges-as-developers-put-ai-coding-agents-on-repeat.aspx)
- [AI新聞 — 「もうプロンプトは書かない」Claude Code開発者が提唱するループエンジニアリング](https://exawizards.com/column/ai-trend/news-07-05-2026-3/)
- [Business Insider Japan — もうプロンプトは書かなくていい…「ループ・エンジニアリング」の時代](https://www.businessinsider.jp/article/2607-what-are-loops-ai-engineering-tips/)
