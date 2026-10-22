# TickTick Native

SwiftとSwiftUIで作る、個人用のmacOS向けTickTickクライアントです。
実装順と検証条件は [BACKLOG.md](BACKLOG.md)、作業規約は [AGENTS.md](AGENTS.md) に記載しています。

## 起動と検証

`TickTickNative.xcodeproj` をXcodeで開き、`TickTickNative` スキームを実行します。
検証環境はXcode 27.1です。
外部ライブラリは使用していません。

署名なしでビルドと自動テストを実行する場合：

```sh
xcodebuild \
  -project TickTickNative.xcodeproj \
  -scheme TickTickNative \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/TickTickNative-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

開発用の署名証明書がないMacでは、ソースの署名設定を変更せずにローカル実行用の署名でビルドできます。
配布用の署名ではありません。

```sh
xcodebuild \
  -project TickTickNative.xcodeproj \
  -scheme TickTickNative \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/TickTickNative-DerivedData \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  build
```

## OAuth接続

1. [TickTick開発者ポータル](https://developer.ticktick.com/manage)で個人用アプリを登録します。
2. リダイレクトURLに `http://127.0.0.1:49217/callback` を登録します。
3. 本アプリの「接続設定」でClient IDとClient Secretを入力します。
4. 「ブラウザで認証」を押し、TickTick上で読み取りを許可します。

認証中だけ `127.0.0.1:49217` でコールバックを受け付け、完了、キャンセル、3分のタイムアウトで受信を停止します。
外部のインターフェースには待ち受けません。

現在要求する権限は `tasks:read` だけです。
トークンと個人用のOAuth設定はKeychainに保存し、リポジトリへ含めません。
再認証も同じ接続設定から行えます。
「このMacの接続を解除」は、保存情報と表示中のタスクを端末から消します。
サーバー側でのトークン失効操作ではありません。

[公式Open API仕様](https://developer.ticktick.com/docs#/openapi)では、認可コードの交換にclient secretを使います。
本アプリは個人用の値を端末で設定する方式とし、配布バイナリへ共通の秘密値を埋め込みません。
PKCEやリフレッシュトークンを使えるとは仮定せず、失効時には再認証します。

## BL-001の取得範囲

- 未アーカイブのリストをページ単位で取得し、各リストのタスクを読み取ります。
- 受信箱の取得方法は未確認のため、取得対象外であることを画面にも表示します。
- 取得できなかったリストと、解釈できない日時は警告します。
- リストやタスクの作成、変更、削除は行いません。
- オフライン保存はまだ行わず、表示中のタスクはメモリ内に保持します。
- 手動更新に失敗した場合は、エラーと前回の取得時刻を表示して直前の内容を保ちます。

## 今日と期限切れの判定

端末の現在のカレンダーとタイムゾーンで日を区切ります。

- 完了済みと放棄済みのタスクは表示しません。
- 終日はAPIに記録された年月日を使い、タイムゾーン変換で日付をずらしません。
- 時刻付きの予定はAPIのオフセットを解釈し、端末のタイムゾーンへ変換します。
- 期限が当日の開始より前なら「期限切れ」に分類します。
- 開始から期限までの予定期間が今日に重なる場合は「今日の予定」に分類します。
- 開始と期限の片方しかない場合は、その日時を予定日時として使います。
- 日付なしのタスクはどちらにも含めません。
- 不正な日時や、開始が期限より後のタスクは警告して除外します。

## 実データを使わない画面確認

次の起動引数で、OAuth接続もKeychainへのアクセスもせずサンプルデータを表示できます。

```sh
open -n /tmp/TickTickNative-DerivedData/Build/Products/Debug/TickTickNative.app --args --demo
```

自動テストでは日付境界、夏時間、終日、予定期間、不正な認証応答、権限不足、一部取得失敗、ページ取得の異常を検証します。
2026-10-23に、本人の操作で実アカウントのOAuth認証、一覧取得、再起動後の復元、接続解除を確認しました。
タスク内容や秘密値を確認用ログやスクリーンショットへ残さないでください。

## 初期の性能確認

2026-10-23のローカルDebug相当の確認では、合成データ1,000件の日時分類が約1.30秒から約0.19秒になりました。
同じデータとコンパイル条件で、日時解析器の再利用前後を比較した値です。
日時分類と一覧の整列はメインスレッド外で行います。
接続待機画面のアドホック署名版では、RSS約37MiB、CPU使用率0.0%を1回確認しています。
実アカウント、大量データ、長時間利用、公式クライアントとの比較は未測定です。
