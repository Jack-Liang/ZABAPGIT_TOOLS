FUNCTION ZFM_GIT_PUSH .
*"----------------------------------------------------------------------
*"*"本地接口：
*"  IMPORTING
*"     VALUE(IV_PACKAGE) TYPE  DEVCLASS
*"     VALUE(IV_COMMENT) TYPE  STRING OPTIONAL
*"     VALUE(IV_USER) TYPE  STRING OPTIONAL
*"     VALUE(IV_PASSWD) TYPE  STRING OPTIONAL
*"     VALUE(IV_DRYRUN) TYPE  CHAR1 OPTIONAL
*"  EXPORTING
*"     VALUE(EV_MESSAGE) TYPE  STRING
*"     VALUE(EV_STAGED) TYPE  I
*"     VALUE(EV_ADDED) TYPE  I
*"     VALUE(EV_MODIFIED) TYPE  I
*"     VALUE(EV_DELETED) TYPE  I
*"     VALUE(EV_SUBRC) TYPE  SYSUBRC
*"     VALUE(ET_LOG) TYPE  BAPIRET2_T
*"----------------------------------------------------------------------
  DATA: lt_log  TYPE string_table,
        ls_line TYPE string,
        ls_ret  TYPE bapiret2.

  CLEAR: ev_message, ev_staged, ev_added, ev_modified, ev_deleted, ev_subrc.
  CLEAR et_log.

  zcl_git_push=>push_by_package(
    EXPORTING
      iv_package  = iv_package
      iv_comment  = iv_comment
      iv_user     = iv_user
      iv_passwd   = iv_passwd
      iv_dryrun   = iv_dryrun
    IMPORTING
      ev_message  = ev_message
      ev_staged   = ev_staged
      ev_added    = ev_added
      ev_modified = ev_modified
      ev_deleted  = ev_deleted
      ev_subrc    = ev_subrc
      et_log      = lt_log ).

  LOOP AT lt_log INTO ls_line.
    CLEAR ls_ret.
    IF ev_subrc = 0.
      ls_ret-type = 'S'.
    ELSE.
      ls_ret-type = 'E'.
    ENDIF.
    ls_ret-message = ls_line.
    APPEND ls_ret TO et_log.
  ENDLOOP.

  IF ev_subrc <> 0 AND lines( et_log ) = 0.
    ls_ret-type = 'E'.
    ls_ret-message = 'push failed'.
    APPEND ls_ret TO et_log.
  ENDIF.

ENDFUNCTION.
