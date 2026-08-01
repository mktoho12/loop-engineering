# 仕様: DELETE /issues/:id

ラウンド1で作り手エージェントに渡す仕様書。**これがループの入力**。

## 背景

`world-issue-tracker` の Issue API には CRUD のうち **Delete だけが未実装**。
既存の `GET /issues/:id` と `PATCH /issues/:id` と同じ流儀で追加する。

## 要件

### エンドポイント

```
DELETE /issues/:id
```

### 振る舞い

| 状況 | ステータス | レスポンスボディ |
|---|---|---|
| 未認証 | 401 | `{ "error": "Unauthorized" }` |
| 対象が存在しない | 404 | `{ "error": "Issue not found" }` |
| 削除成功 | 200 | 削除された Issue オブジェクト |

- **認証必須**。既存の `POST` / `PATCH` と同じく `requireAuth` ミドルウェアで保護する
- 削除は物理削除（論理削除フラグは導入しない）
- 削除した Issue の内容を返す（`DELETE ... RETURNING *` を使う）

### 実装方針

- `apps/api/src/routes/issues.ts` に追加する
- 既存の `PATCH /issues/:id` と同じパターンに揃える（404 判定の仕方、エラーレスポンスの形）
- D1 の `RETURNING *` を使い、削除と取得を1クエリで行う

### テスト

`apps/api/test/issues.test.ts` に `describe("DELETE /issues/:id")` を追加し、
最低限以下をカバーすること:

1. 認証済みユーザーが自分の Issue を削除でき、200 と削除された Issue が返る
2. 削除後に `GET /issues/:id` を叩くと 404 になる
3. 存在しない ID を削除しようとすると 404
4. 未認証だと 401

既存のヘルパ（`createIssue()`, `readBody()`）と `beforeEach` の DB クリアをそのまま使う。

## 制約

- パッケージマネージャは **bun**
- リンター/フォーマッターは **Biome**（インデントは**タブ**）
- テストは **vitest**
- 既存のテストを壊さないこと

## 完了条件（このラウンドの停止条件 = 素朴版）

以下の3つがすべて exit 0 になること:

```
bun run test
bun run lint
bun run check
```

---

## 【実験メモ｜作り手エージェントには見せない】

この仕様には**意図的に穴**が開けてある。

**罠**: `apps/api/src/index.ts` の CORS 設定に `allowMethods: ["GET", "POST", "PATCH", "OPTIONS"]` とあり、
`DELETE` が含まれていない。これを足さないと、ブラウザからの DELETE リクエストは
プリフライトで拒否されて**実際には動かない**。

**なぜこれが良い罠か**: この見落としは **vitest では絶対に検出できない**。
テストは Hono アプリを `app.request()` で直接叩くため、ブラウザのプリフライト
(OPTIONS リクエスト) を経由しないから。つまり:

- ✅ `bun run test` → 通る
- ✅ `bun run lint` → 通る
- ✅ `bun run check` → 通る
- ❌ **実際のブラウザからは動かない**

素朴な3条件ループは「完了」と判定して停止する。**これがフェーズAで観察したいこと**。

フェーズBでは停止条件を拡張し、これを機械的に捕まえられるか試す。
