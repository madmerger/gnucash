# Windows 32/64 ビットビルドキット

> **注意:** `x86_64` は実験的です。MinGW64 では Guile 2.2.7、3.0.10、3.0.11 のいずれも `ice-9/eval.go` のブートストラップに失敗するため、ビルド完了は期待できません。サポート対象は `i686` です。

このディレクトリには、Windows 用 GnuCash の 32/64 ビットビルド手順と起動用テンプレートを収録しています。Windows Server 2022 / Windows 10・11、PowerShell、Git for Windows を前提とします。

## ビルド

1. `gnucash-on-windows` リポジトリを `$HOME\repos\gnucash-on-windows` に clone します。
2. このリポジトリのルートで、次を実行します。

   ```powershell
   .\util\windows\build-gnucash.ps1 `
     -TargetDir C:\gcdev64 `
     -GnucashRepo C:\Users\Administrator\repos\gnucash `
     -GnucashBranch stable
   ```

   32 ビット版を作成する場合は次のように指定します。i686 では既定の Guile 2 モジュールを使います。

   ```powershell
   .\util\windows\build-gnucash.ps1 `
     -TargetDir C:\gcdev32 `
     -Architecture i686 `
     -GnucashRepo C:\Users\Administrator\repos\gnucash `
     -GnucashBranch stable
   ```

スクリプトは公式の `setup-mingw64.ps1` で選択したアーキテクチャの MSYS2 環境を準備し、GCC 15.2.0-14 / gcc-libs 15.2.0-14、SWIG 4.2.1-1 と CMake 関連パッケージを対応する MSYS2 アーカイブから固定します。i686 ではアーカイブ内の各パッケージの `.PKGINFO` を再帰的に読み、WebKitGTK、GTK3 と jhbuild の依存パッケージを解決してインストールします。パッケージの一括更新で GCC 16 に戻らないよう、対象を `pacman.conf` の `IgnorePkg` に登録してから jhbuild を実行します。x86_64 では Guile 3.0.11、i686 では既定の Guile 2 を使います。GnuCash のソースは指定したローカル Git リポジトリとブランチを使います。AQBanking、OFX、Python は無効、SQL (SQLite) は有効です。

WebKitGTK / JavaScriptCore の配布済み依存ライブラリは GCC 15 でビルドされています。GCC 16 の libstdc++ では `__emutls` 関連シンボルの不一致が発生するため、C++ ツールチェーンを揃えて固定します。再び MSYS2 のパッケージを更新する場合は、同じ固定を維持してください。

## 起動

`launch-gnucash.bat.in` の `@GNC_HOME@` と `@MSYS2_MINGW@` をそれぞれインストール先と MinGW ディレクトリ (`C:\gcdev64\msys2\mingw64` または `C:\gcdev32\msys2\mingw32`) に置き換えて `.bat` として保存し、そこから起動します。`PATH` と `XDG_DATA_DIRS` には GnuCash と MinGW のディレクトリを含めます。後者は GTK の GSettings スキーマを見つけるために必要です。

## 制限事項

- WebKitGTK 1.x (2.4.11) は互換性上の理由から残しています。
- ヘルプマニュアルはこのビルドに含まれません。
