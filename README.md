# ZABAPGIT_TOOLS

基于 abapGit 的 SAP 自动提交工具：按开发包（Package）扫描本地对象与远端 Git 仓库的差异，自动生成带差异统计的 commit message 并推送，同时提供 RFC 函数模块，支持外部系统远程触发提交。

## 功能特性

- **按包推送**：传入开发包（DEVCLASS），自动定位其对应的 abapGit 在线仓库并计算差异
- **智能 commit message**：首行自动生成「包名 + 日期(YYMMDD) + 时间 + 差异统计（+新增 ~修改 -删除）」，正文附完整变更对象清单；传入自定义描述时，统计信息自动下沉到正文
- **传输请求（TR）关联**：自动从 E071/E070/E07T 提取对象所属请求号及描述，写入 commit 正文（本地包 $ 开头的对象无 TR，自动跳过）
- **Dry-run 模式**：只计算差异并生成提交信息，不实际推送，便于调用方先确认「改了什么」
- **RFC 远程调用**：RFC 启用的函数模块 ZFM_GIT_PUSH，外部系统可远程触发提交
- **认证注入**：支持 Basic 认证（用户名/密码）写入 abapGit 登录管理器

## 组件清单

| 对象 | 类型 | 说明 |
| --- | --- | --- |
| `ZCL_GIT_PUSH` | 全局类 | 核心逻辑：差异收集、commit message 构建、stage & push |
| `ZGIT_PUSH_RFC` | 函数组 | RFC 封装层 |
| `ZFM_GIT_PUSH` | 函数模块（RFC 可用） | 按包推送的远程调用入口，日志以 BAPIRET2_T 返回 |

## 前提条件

- SAP 系统已安装 [abapGit](https://github.com/abapGit/abapGit)
- 目标开发包已通过 abapGit 关联在线（Online）仓库

## 安装

通过 abapGit 将本仓库以 Online 方式克隆到 SAP 系统并激活对象即可。

## 使用

### ABAP 系统内调用

```abap
DATA: lv_msg     TYPE string,
      lv_staged  TYPE i,
      lv_subrc   TYPE sysubrc,
      lt_log     TYPE string_table.

zcl_git_push=>push_by_package(
  EXPORTING
    iv_package = 'ZMY_PACKAGE'      " 开发包
    iv_comment = '自定义提交说明'     " 可选，不传则自动生成
    iv_dryrun  = abap_true          " 可选，只预览不推送
  IMPORTING
    ev_message = lv_msg             " 最终使用的 commit message
    ev_staged  = lv_staged          " 待提交文件数
    ev_subrc   = lv_subrc
    et_log     = lt_log ).
```

### RFC 远程调用

调用函数模块 `ZFM_GIT_PUSH`：

| 参数 | 方向 | 类型 | 说明 |
| --- | --- | --- | --- |
| `IV_PACKAGE` | 导入 | DEVCLASS | 开发包 |
| `IV_COMMENT` | 导入 | STRING（可选） | 自定义 commit 说明 |
| `IV_USER` / `IV_PASSWD` | 导入 | STRING（可选） | Git 仓库 Basic 认证 |
| `IV_DRYRUN` | 导入 | CHAR1（可选） | `X` = 只算差异不推送 |
| `EV_MESSAGE` | 导出 | STRING | commit message |
| `EV_STAGED` / `EV_ADDED` / `EV_MODIFIED` / `EV_DELETED` | 导出 | I | 差异统计 |
| `EV_SUBRC` | 导出 | SYSUBRC | 返回码 |
| `ET_LOG` | 导出 | BAPIRET2_T | 过程日志 |

### 返回码

| EV_SUBRC | 含义 |
| --- | --- |
| 0 | 推送成功（或无差异可提交） |
| 4 | 包未关联 abapGit 仓库，或仓库为离线（Offline）模式 |
| 8 | 推送异常，详情见 `ET_LOG` |

## Commit message 示例

```
$ZGIT_TOOLS 261031 12:46 +0 ~1 -0

TR SIDK900123 修复推送工具差异统计逻辑
~ CLAS ZCL_GIT_PUSH
```

## 说明

- committer 默认取当前 SAP 用户（`SY-UNAME`），可通过 `IV_NAME` / `IV_EMAIL` 覆盖
- 差异判定基于 abapGit stage logic 的逐文件状态（`lstate`），同一对象的 `.abap` 与 `.xml` 若分别处于新增/修改，按「修改」归类
