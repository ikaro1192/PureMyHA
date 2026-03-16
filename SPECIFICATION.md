# PureMyHA 仕様書

## 1. 概要

**PureMyHA** は MySQL 8.4 に対応した Haskell 製のシンプルな HA (High Availability) ツールである。
Orchestrator の設計思想を参考に、レプリケーショントポロジーの探索・障害検知・自動フェイルオーバーを提供する。

- **対象 MySQL バージョン**: 8.4 以降
- **目的**: 単一障害点を排除し、MySQL レプリケーション構成の可用性を高める
- **設計方針**: シンプルさを優先し、過度な機能追加を避ける

---

## 2. システム要件

### MySQL 要件
- MySQL 8.4 以降
- GTID 必須 (`gtid_mode=ON`, `enforce_gtid_consistency=ON`)
- MySQL 8.4 で廃止された旧構文は一切使用しない (詳細は「11. MySQL 8.4 対応事項」参照)

### 必要な MySQL 権限
```sql
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'purermyha'@'%';
GRANT SUPER ON *.* TO 'purermyha'@'%';
-- または MySQL 8.0+ の細粒度権限:
GRANT REPLICATION_SLAVE_ADMIN, REPLICATION_APPLIER ON *.* TO 'purermyha'@'%';
GRANT SYSTEM_VARIABLES_ADMIN ON *.* TO 'purermyha'@'%';
```

### 実行環境
- OS: Linux
- 言語: Haskell (GHC 9.x 以降)
- PureMyHA 自体の冗長化には Pacemaker + QDevice を使用

---

## 3. アーキテクチャ

### コンポーネント

| コンポーネント | 役割 |
|--------------|------|
| `purermyhad` | 常駐デーモン。トポロジー監視・障害検知・自動フェイルオーバーを担当 |
| `purermyha`  | CLI ツール。状態確認・手動操作のインターフェース |

デーモンと CLI の通信は **Unix ドメインソケット** (`/run/purermyhad.sock`) 経由で行う。

### PureMyHA 自体の冗長化 (Pacemaker + QDevice)

```
Node1 (Active)  ─── Corosync/Pacemaker ───  Node2 (Standby)
                            │
                       QDevice (仲裁用軽量ノード)
```

**Pacemaker リソース構成例:**
```
- purermyhad  (Active/Standby クローンリソース)
- VIP         (オプション: アプリ向け浮遊 IP)
- STONITH     (フェンシング必須。Split-Brain 防止のため必ず設定すること)
```

**設計上の制約:**
- PureMyHA 自体はリーダー選出ロジックを持たない。リーダー選出は Pacemaker に全面委任する。
- デーモンの状態はメモリのみに保持する。再起動時は MySQL から再スキャンして状態を再構築する。

---

## 4. 設定ファイル (YAML)

デフォルトパス: `/etc/purermyha/config.yaml`

```yaml
clusters:
  - name: main
    nodes:
      - host: db1
        port: 3306
      - host: db2
        port: 3306
    credentials:
      user: purermyha
      password_file: /etc/purermyha/mysql.pass

monitoring:
  interval: 3s
  connect_timeout: 2s
  replication_lag_warning: 10s
  replication_lag_critical: 30s

failure_detection:
  recovery_block_period: 3600s   # フェイルオーバー後の自動回復ブロック期間

failover:
  auto_failover: true
  min_replicas_for_failover: 1   # 自動フェイルオーバーに必要な最低レプリカ数
  candidate_priority:            # 昇格候補の優先順位 (省略時は GTID で自動判定)
    - host: db2

hooks:
  pre_failover: /etc/purermyha/hooks/pre_failover.sh
  post_failover: /etc/purermyha/hooks/post_failover.sh
  pre_switchover: /etc/purermyha/hooks/pre_switchover.sh
  post_switchover: /etc/purermyha/hooks/post_switchover.sh
```

---

## 5. トポロジー探索

1. 設定ファイルのシードホストに接続し、`SHOW REPLICA STATUS` を再帰的にたどってレプリケーション木を構築する。
2. ソースノードに対しては `SHOW BINARY LOG STATUS` で binlog 状態を取得する。
3. **ソースとレプリカ双方から状態を取得**し、多角的に把握することで誤検知を減らす。
4. 定期ポーリング (デフォルト 3 秒)。各ノードは独立したスレッドで並行監視する。

---

## 6. 障害検知

### Failure Scenarios

| シナリオ | 定義 |
|---------|------|
| `Healthy` | 正常稼働中 |
| `DeadSource` | ソース接続不可。かつレプリカでも `Replica_IO_Running = No` を確認 |
| `UnreachableSource` | ソース接続不可。ただしレプリカからはソースに到達できる (ネットワーク分断の疑い) |
| `DeadSourceAndAllReplicas` | ソースおよび全レプリカが応答しない |
| `SplitBrainSuspected` | 複数ノードがソースとして動作している疑い |
| `NeedsAttention String` | その他の異常。詳細メッセージを付与して報告 |

### Anti-Flap

フェイルオーバー後は `recovery_block_period` 秒間、自動フェイルオーバーをブロックする。
CLI コマンド `purermyha ack-recovery` で手動解除できる。

---

## 7. 自動フェイルオーバー

`DeadSource` を検知した場合、デーモンが以下の手順を自動実行する。

```
1. Pre-failover フック実行
2. 昇格候補の選定
   a. Executed_Gtid_Set が最も進んでいるレプリカを優先
   b. Errant GTID を持つレプリカは除外
   c. 設定の candidate_priority も考慮
3. 昇格
   a. 候補レプリカで STOP REPLICA
   b. RESET REPLICA ALL
   c. 新ソースとして動作開始 (read_only=OFF)
4. 残レプリカの再接続
   CHANGE REPLICATION SOURCE TO
     SOURCE_HOST='<新ソース>',
     SOURCE_PORT=3306,
     SOURCE_AUTO_POSITION=1;
   START REPLICA;
5. Post-failover フック実行
6. recovery_block_period のセット (Anti-Flap)
```

---

## 8. スイッチオーバー (手動)

計画メンテナンス向けの手動操作。`purermyha switchover` で実行する。
`--to` オプションで昇格先ホストを明示指定できる。

```
1. Pre-switchover フック実行
2. 旧ソースが生存している場合: read_only=ON に設定
   旧ソースが応答しない場合: そのまま次へ (緊急スイッチオーバー)
3. 昇格先の選定
   - --to 指定あり: 指定ホストを使用
   - --to 省略時: Executed_Gtid_Set と candidate_priority で自動選定
4. 対象レプリカの Executed_Gtid_Set が旧ソースに追いつくまで待機
5. 昇格・残レプリカ再接続 (自動フェイルオーバーと同じフロー)
6. 旧ソースが生存していた場合: 新レプリカとして接続
7. Post-switchover フック実行
```

---

## 9. Errant GTID 管理

**検出:** 全レプリカの `Executed_Gtid_Set` を比較し、ソースに存在しない GTID (Errant GTID) を検出する。
検出したレプリカは `NeedsAttention` として報告し、自動フェイルオーバーの昇格候補から除外する。

**修復:** Errant GTID に対応する空トランザクション (empty transaction) をソースに注入することで整合性を回復する。
`purermyha fix-errant-gtid` コマンドで実行する。

---

## 10. CLI サブコマンド

```
purermyha status
    トポロジーと各ノードの健全性を表示する

purermyha topology
    レプリケーション木をツリー形式で表示する

purermyha switchover [--to=<host>] [--cluster=<name>]
    手動スイッチオーバーを実行する
    --to 省略時は Executed_Gtid_Set と candidate_priority に基づき自動選定

purermyha ack-recovery [--cluster=<name>]
    Anti-Flap による自動回復ブロックを手動解除する

purermyha errant-gtid [--cluster=<name>]
    Errant GTID を検出して表示する

purermyha fix-errant-gtid [--cluster=<name>]
    Errant GTID を空トランザクションで修復する
```

---

## 11. MySQL 8.4 対応事項

MySQL 8.4 では以下の旧構文が廃止された。PureMyHA は旧構文を一切使用しない。

| 旧構文 (使用禁止) | 新構文 |
|-----------------|--------|
| `SHOW SLAVE STATUS` | `SHOW REPLICA STATUS` |
| `SHOW MASTER STATUS` | `SHOW BINARY LOG STATUS` |
| `CHANGE MASTER TO` | `CHANGE REPLICATION SOURCE TO` |
| `START SLAVE` / `STOP SLAVE` | `START REPLICA` / `STOP REPLICA` |
| `RESET SLAVE` | `RESET REPLICA` |

---

## 12. 技術スタック

| 用途 | ライブラリ |
|------|-----------|
| DB 接続 | `mysql-haskell` (pure Haskell、C ライブラリ依存なし) |
| 設定ファイル | `yaml` + `optparse-applicative` |
| 並行処理 | `async` + `STM` (各ノードを独立スレッドで監視) |
| ログ | `katip` (構造化ログ、JSON 出力対応) |
