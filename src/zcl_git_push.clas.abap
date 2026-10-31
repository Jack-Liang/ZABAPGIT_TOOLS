CLASS zcl_git_push DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.

    CLASS-METHODS push_by_package
      IMPORTING
        !iv_package  TYPE devclass
        !iv_comment  TYPE string OPTIONAL
        !iv_name     TYPE string OPTIONAL
        !iv_email    TYPE string OPTIONAL
        !iv_user     TYPE string OPTIONAL
        !iv_passwd   TYPE string OPTIONAL
        !iv_dryrun   TYPE abap_bool DEFAULT abap_false
      EXPORTING
        !ev_message  TYPE string
        !ev_staged   TYPE i
        !ev_added    TYPE i
        !ev_modified TYPE i
        !ev_deleted  TYPE i
        !ev_subrc    TYPE sysubrc
        !et_log      TYPE string_table .

  PRIVATE SECTION.

    CONSTANTS c_max_subject TYPE i VALUE 72 .

    CLASS-METHODS collect_changes
      IMPORTING
        !is_files    TYPE zif_abapgit_definitions=>ty_stage_files
      EXPORTING
        !et_added    TYPE string_table
        !et_modified TYPE string_table
        !et_deleted  TYPE string_table
        !ev_added    TYPE i
        !ev_modified TYPE i
        !ev_deleted  TYPE i .

    CLASS-METHODS build_comment
      IMPORTING
        !iv_package  TYPE devclass
        !iv_manual   TYPE string OPTIONAL
        !it_added    TYPE string_table
        !it_modified TYPE string_table
        !it_deleted  TYPE string_table
      RETURNING
        VALUE(rv_comment) TYPE string .

    CLASS-METHODS stage_and_push
      IMPORTING
        !io_repo    TYPE REF TO zif_abapgit_repo_online
        !iv_name    TYPE string
        !iv_email   TYPE string
        !iv_comment TYPE string
        !is_files   TYPE zif_abapgit_definitions=>ty_stage_files
      CHANGING
        !ct_log     TYPE string_table
      RAISING
        zcx_abapgit_exception .

    CLASS-METHODS tr_text
      IMPORTING
        !iv_obj_type TYPE tadir-object
        !iv_obj_name TYPE tadir-obj_name
      EXPORTING
        !ev_trkorr   TYPE trkorr
        !ev_text     TYPE as4text .

ENDCLASS.



CLASS zcl_git_push IMPLEMENTATION.


  METHOD tr_text.

    DATA lv_strkorr TYPE trkorr.

    CLEAR: ev_trkorr, ev_text, lv_strkorr.

    " 取最近一次所在请求。UP TO n ROWS 必须紧跟在 INTO 之后，
    " 写在 WHERE / ORDER BY 之后会从句法上被当成字段列表的一部分（报未知列名 UP）
    SELECT trkorr FROM e071 INTO ev_trkorr
      UP TO 1 ROWS
      WHERE pgmid = 'R3TR'
        AND object = iv_obj_type
        AND obj_name = iv_obj_name
      ORDER BY trkorr DESCENDING.
    ENDSELECT.

    " 开发中对象的 E071 记的是「任务号」；任务→请求的归属在 E070 的 STRKORR。
    " 对外一律给请求号，任务号只用于自己定位。
    IF ev_trkorr IS NOT INITIAL.
      SELECT SINGLE strkorr FROM e070 INTO lv_strkorr
        WHERE trkorr = ev_trkorr.
      IF lv_strkorr IS NOT INITIAL.
        ev_trkorr = lv_strkorr.
      ENDIF.
    ENDIF.

    IF ev_trkorr IS INITIAL.
      RETURN.
    ENDIF.

    SELECT SINGLE as4text FROM e07t INTO ev_text
      WHERE trkorr = ev_trkorr
        AND langu = sy-langu.
    IF sy-subrc <> 0.
      SELECT SINGLE as4text FROM e07t INTO ev_text
        WHERE trkorr = ev_trkorr
          AND langu = 'E'.
    ENDIF.

  ENDMETHOD.


  METHOD collect_changes.

    DATA: lv_line TYPE string,
          lv_obj  TYPE string,
          lv_key  TYPE string.

    FIELD-SYMBOLS: <ls_local>  LIKE LINE OF is_files-local,
                   <ls_remote> LIKE LINE OF is_files-remote.

    CLEAR: et_added, et_modified, et_deleted,
           ev_added, ev_modified, ev_deleted.

    " local = 本地与远端不一致的文件（新增或修改）。
    " stage logic 只返回有差异的文件，所以「远端已有同名文件」= 修改，否则 = 新增。
    LOOP AT is_files-local ASSIGNING <ls_local>.
      READ TABLE is_files-remote TRANSPORTING NO FIELDS
        WITH KEY path     = <ls_local>-file-path
                 filename = <ls_local>-file-filename.
      IF sy-subrc = 0.
        lv_line = |~ { <ls_local>-item-obj_type } { <ls_local>-item-obj_name }|.
        APPEND lv_line TO et_modified.
      ELSE.
        lv_line = |+ { <ls_local>-item-obj_type } { <ls_local>-item-obj_name }|.
        APPEND lv_line TO et_added.
      ENDIF.
    ENDLOOP.

    " remote = 远端有、本地没有的文件 → 删除。remote 表只有文件级信息，没有 item，
    " 因此这里按文件路径列出（.abap/.xml 各一行），这也是 abapGit 自己的做法。
    LOOP AT is_files-remote ASSIGNING <ls_remote>.
      lv_line = |{ <ls_remote>-path }{ <ls_remote>-filename }|.
      APPEND lv_line TO et_deleted.
    ENDLOOP.

    SORT et_added.
    DELETE ADJACENT DUPLICATES FROM et_added.
    SORT et_modified.
    DELETE ADJACENT DUPLICATES FROM et_modified.
    SORT et_deleted.
    DELETE ADJACENT DUPLICATES FROM et_deleted.

    " 同一对象的 .abap 与 .xml 可能一个新增一个修改（例如对象新建后只改了源码），
    " 此时按「修改」归类，避免同一对象同时计入新增和修改。
    LOOP AT et_modified INTO lv_obj.
      lv_key = |+ { lv_obj+2 }|.
      DELETE et_added WHERE table_line = lv_key.
    ENDLOOP.

    ev_added    = lines( et_added ).
    ev_modified = lines( et_modified ).
    ev_deleted  = lines( et_deleted ).

  ENDMETHOD.


  METHOD build_comment.

    DATA: lv_date   TYPE c LENGTH 6,
          lv_time   TYPE c LENGTH 6,
          lv_hhmm   TYPE string,
          lv_head   TYPE string,
          lv_stat   TYPE string,
          lv_sym    TYPE c LENGTH 1,
          lv_obj    TYPE string,
          lv_type   TYPE tadir-object,
          lv_onam   TYPE tadir-obj_name,
          lv_trkorr TYPE trkorr,
          lv_trtext TYPE as4text.

    " 日期固定 YYMMDD：sy-datum 内部恒为 YYYYMMDD，取后 6 位；
    " 不用 DATE = USER/ENVIRONMENT，那跟用户主数据日期格式走，换人登录就变
    lv_date = sy-datum+2(6).
    lv_time = sy-uzeit.
    lv_hhmm = lv_time(2) && ':' && lv_time+2(2).

    lv_stat = |+{ lines( it_added ) } ~{ lines( it_modified ) } -{ lines( it_deleted ) }|.

    " TR 号与描述只对「传输包」有效。本地包（$ 开头）的对象不写 E071，
    " 这里恒为空，commit message 就完全由 diff 统计支撑。
    LOOP AT it_added INTO lv_obj.
      SPLIT lv_obj AT ' ' INTO lv_sym lv_type lv_onam.
      tr_text( EXPORTING iv_obj_type = lv_type
                         iv_obj_name = lv_onam
               IMPORTING ev_trkorr   = lv_trkorr
                         ev_text     = lv_trtext ).
      IF lv_trtext IS NOT INITIAL.
        EXIT.
      ENDIF.
    ENDLOOP.
    IF lv_trtext IS INITIAL.
      LOOP AT it_modified INTO lv_obj.
        SPLIT lv_obj AT ' ' INTO lv_sym lv_type lv_onam.
        tr_text( EXPORTING iv_obj_type = lv_type
                           iv_obj_name = lv_onam
                 IMPORTING ev_trkorr   = lv_trkorr
                           ev_text     = lv_trtext ).
        IF lv_trtext IS NOT INITIAL.
          EXIT.
        ENDIF.
      ENDLOOP.
    ENDIF.

    " 首行：外部给了描述就用它，否则用「包 + 时间 + 差异统计」。
    " TR 描述不拼进首行——它是"这批对象挂在哪张单上"，不是"改了什么"，
    " 拼上去会把主题挤爆（首行还要截到 72 字符），且本地包根本没有 TR。
    IF iv_manual IS NOT INITIAL.
      lv_head = iv_manual.
    ELSE.
      lv_head = |{ iv_package } { lv_date } { lv_hhmm } { lv_stat }|.
    ENDIF.
    IF strlen( lv_head ) > c_max_subject.
      lv_head = lv_head(c_max_subject) && '...'.
    ENDIF.

    rv_comment = lv_head.

    " 外部描述占用了首行，统计与 TR 信息下沉到正文，保证信息不丢
    IF iv_manual IS NOT INITIAL.
      rv_comment = rv_comment && cl_abap_char_utilities=>newline
                             && |{ iv_package } { lv_date } { lv_hhmm } { lv_stat }|.
    ENDIF.
    IF lv_trkorr IS NOT INITIAL.
      rv_comment = rv_comment && cl_abap_char_utilities=>newline
                             && |TR { lv_trkorr } { lv_trtext }|.
    ENDIF.

    LOOP AT it_added INTO lv_obj.
      rv_comment = rv_comment && cl_abap_char_utilities=>newline && lv_obj.
    ENDLOOP.
    LOOP AT it_modified INTO lv_obj.
      rv_comment = rv_comment && cl_abap_char_utilities=>newline && lv_obj.
    ENDLOOP.
    LOOP AT it_deleted INTO lv_obj.
      rv_comment = rv_comment && cl_abap_char_utilities=>newline && |D { lv_obj }|.
    ENDLOOP.

  ENDMETHOD.


  METHOD stage_and_push.

    DATA: lo_stage   TYPE REF TO zcl_abapgit_stage,
          ls_comment TYPE zif_abapgit_git_definitions=>ty_comment,
          lv_line    TYPE string.

    FIELD-SYMBOLS: <ls_local>  LIKE LINE OF is_files-local,
                   <ls_remote> LIKE LINE OF is_files-remote.

    CREATE OBJECT lo_stage.

    LOOP AT is_files-local ASSIGNING <ls_local>.
      lv_line = |stage { <ls_local>-file-path } { <ls_local>-file-filename }|.
      APPEND lv_line TO ct_log.
      lo_stage->add( iv_path     = <ls_local>-file-path
                     iv_filename = <ls_local>-file-filename
                     iv_data     = <ls_local>-file-data ).
    ENDLOOP.

    LOOP AT is_files-remote ASSIGNING <ls_remote>.
      lv_line = |rm    { <ls_remote>-path } { <ls_remote>-filename }|.
      APPEND lv_line TO ct_log.
      lo_stage->rm( iv_path     = <ls_remote>-path
                    iv_filename = <ls_remote>-filename ).
    ENDLOOP.

    ls_comment-committer-name  = iv_name.
    ls_comment-committer-email = iv_email.
    ls_comment-comment         = iv_comment.

    io_repo->push( is_comment = ls_comment
                   io_stage   = lo_stage ).

    APPEND |pushed: { iv_comment }| TO ct_log.

  ENDMETHOD.


  METHOD push_by_package.

    DATA: lo_repo     TYPE REF TO zif_abapgit_repo,
          lo_online   TYPE REF TO zif_abapgit_repo_online,
          ls_files    TYPE zif_abapgit_definitions=>ty_stage_files,
          lv_name     TYPE string,
          lv_email    TYPE string,
          lv_reason   TYPE string,
          lv_line     TYPE string,
          lt_added    TYPE string_table,
          lt_modified TYPE string_table,
          lt_deleted  TYPE string_table,
          lx_error    TYPE REF TO zcx_abapgit_exception.

    CLEAR: ev_message, ev_staged, ev_added, ev_modified, ev_deleted, ev_subrc.
    CLEAR et_log.

    TRY.
        zcl_abapgit_repo_srv=>get_instance( )->get_repo_from_package(
          EXPORTING iv_package = iv_package
          IMPORTING ei_repo    = lo_repo
                    ev_reason  = lv_reason ).

        IF lo_repo IS NOT BOUND.
          ev_subrc = 4.
          APPEND |package { iv_package } has no abapGit repository { lv_reason }| TO et_log.
          RETURN.
        ENDIF.

        IF lo_repo->is_offline( ) = abap_true.
          ev_subrc = 4.
          APPEND |repository of { iv_package } is offline| TO et_log.
          RETURN.
        ENDIF.

        lo_online ?= lo_repo.

        IF iv_user IS NOT INITIAL.
          zcl_abapgit_login_manager=>set_basic(
            iv_uri      = lo_online->get_url( )
            iv_username = iv_user
            iv_password = iv_passwd ).
        ENDIF.

        ls_files = zcl_abapgit_stage_logic=>get_stage_logic( )->get( lo_online ).

        collect_changes( EXPORTING is_files    = ls_files
                         IMPORTING et_added    = lt_added
                                   et_modified = lt_modified
                                   et_deleted  = lt_deleted
                                   ev_added    = ev_added
                                   ev_modified = ev_modified
                                   ev_deleted  = ev_deleted ).

        ev_staged = ev_added + ev_modified + ev_deleted.
        IF ev_staged = 0.
          APPEND 'nothing to stage' TO et_log.
          RETURN.
        ENDIF.

        ev_message = build_comment( iv_package  = iv_package
                                    iv_manual   = iv_comment
                                    it_added    = lt_added
                                    it_modified = lt_modified
                                    it_deleted  = lt_deleted ).

        " 只算差异、不落提交：让调用方先看到「改了什么」，再决定 commit 描述
        IF iv_dryrun = abap_true.
          APPEND 'dry-run: nothing pushed [v393]' TO et_log.
          RETURN.
        ENDIF.

        lv_name  = iv_name.
        lv_email = iv_email.
        IF lv_name IS INITIAL.
          lv_name = sy-uname.
        ENDIF.
        IF lv_email IS INITIAL.
          lv_email = |{ sy-uname }@localhost|.
        ENDIF.

        stage_and_push( EXPORTING io_repo    = lo_online
                                  iv_name    = lv_name
                                  iv_email   = lv_email
                                  iv_comment = ev_message
                                  is_files   = ls_files
                        CHANGING  ct_log     = et_log ).

      CATCH zcx_abapgit_exception INTO lx_error.
        ev_subrc = 8.
        lv_line = lx_error->get_text( ).
        APPEND lv_line TO et_log.
    ENDTRY.

  ENDMETHOD.

ENDCLASS.

