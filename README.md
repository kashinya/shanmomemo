# メモ帳 for Mac

Windows 95〜10 のメモ帳みたいな、ただのテキストエディタ。

Mac のただのメモ帳（テキストエディタ）。表示を SEDIT 風にすると、PC-98（PC-9801）の MS-DOS で見てたあの黒い画面と、16 ドットの 98 フォントになる。自分でビルドする用。
pc-98 pc98 pc-9801 sedit ms-dos retro retrocomputing macos text-editor notepad japanese shift-jis swift appkit

## ビルドとインストール

Xcode 本体は要らない。コマンドラインツールだけでいい。

```sh
xcode-select --install      # 入れてなければ。入ってたら「already installed」と出る
cd Memocho                  # この zip を展開したフォルダ
./build.sh install          # ビルドして /Applications/メモ帳.app に入れる
```

`./build.sh` だけなら `build/メモ帳.app` ができるだけ（好きな場所に置けばいい）。
Intel Mac と Apple シリコンの両方で動くユニバーサル版になる。macOS 10.15 以降（Apple シリコンは 11 以降）。

自分の Mac でビルドしたアプリなので、Gatekeeper の「開発元を確認できません」は出ない。

### .txt をダブルクリックでこれが開くようにする

Finder で .txt ファイルを選んで ⌘I →「このアプリケーションで開く」で「メモ帳」を選んで「すべてを変更…」。
.php や .csv も同じ要領でいける。どのファイルでも「このアプリケーションで開く」の候補には出る。

## Windows のメモ帳との対応

| Windows | このアプリ | メモ |
|---|---|---|
| Ctrl+N 新規 | ⌘N | **今のウィンドウの中身を入れ替える**（Windows と同じ） |
| Ctrl+Shift+N 新しいウィンドウ | ⇧⌘N | |
| Ctrl+O 開く | ⌘O | **今のウィンドウで開く**（Windows と同じ）。Finder から開いたときは別ウィンドウ |
| Ctrl+S / Ctrl+Shift+S | ⌘S / ⇧⌘S | 保存ダイアログで文字コードと改行コードを選べる |
| Ctrl+P 印刷 | ⌘P | ページ設定は ⇧⌘P |
| Ctrl+F 検索 | ⌘F | Windows と同じ形の検索ダイアログ（方向・大文字小文字・折り返し） |
| F3 / Shift+F3 | ⌘G / ⇧⌘G | fn+F3 も効く |
| Ctrl+H 置換 | ⌥⌘F | ⌘H は Mac では「隠す」なので |
| Ctrl+G 行へ移動 | ⌘L | ⌘G は Mac では「次を検索」なので |
| F5 日付と時刻 | F5 | Mac のキーボードなら fn+F5。「15:37 2026/10/21」形式 |
| Ctrl+プラス/マイナス/0 ズーム | ⌘+ / ⌘- / ⌘0 | トラックパッドのピンチでも |
| 書式 > 右端で折り返す | 同じ | |
| 書式 > フォント | ⌘T | |
| 表示 > ステータス バー | 同じ | 行・列、ズーム、改行コード、文字コードを表示 |
| ファイルをウィンドウにドロップ | 同じ | 今のウィンドウで開く |

`.LOG` で始まるファイルを開くと末尾に日時が足される、Windows の隠し機能も入れてある。

## 文字コード

開くときは自動判定。順番は BOM → BOM なし UTF-16 → UTF-8 → Shift_JIS / EUC-JP。

- Shift_JIS は Windows と同じ CP932（①、㈱、～ なども Windows どおり）
- 判定を外したときは［ファイル］→［文字コードを指定して開き直す］か、開くダイアログ下の「文字コード」で指定
- 保存は元の文字コード・改行コードのまま。変えたいときは［書式］→［保存時の文字コード］［保存時の改行コード］か、名前を付けて保存のダイアログで
- 新規ファイルは UTF-8 / LF
- Shift_JIS で表せない文字（絵文字など）が入ってたら、保存の前に聞いてくる
- 上書き保存は中身だけ差し替えるので、ファイルの権限（シェルスクリプトの実行権限とか）やシンボリックリンクはそのまま

## 覚えている設定

フォント、折り返し、ステータスバー、最後のウィンドウ位置と大きさ、検索のオプションだけ。

隠し設定: タブ幅（初期値は Windows と同じ 8）

```sh
defaults write local.memocho TabWidth -int 4
```

設定をまっさらに戻す / アンインストール:

```sh
defaults delete local.memocho
rm -rf "/Applications/メモ帳.app"
```

## 中身

- `Sources/` … Swift（AppKit）。Xcode プロジェクトなし、`build.sh` が swiftc を直接呼ぶ
- `Resources/AppIcon.icns` … アイコン
- アプリ名を変えたいとき: `APP_NAME=Notepad ./build.sh`
