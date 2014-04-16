CREATE OR REPLACE PACKAGE BODY "APEXIR_XLSX_PKG" 
AS


/* Constants */
  c_bulk_size CONSTANT pls_integer := 200;
  
  c_col_data_type_vc CONSTANT VARCHAR2(30) := 'VARCHAR';
  c_col_data_type_num CONSTANT VARCHAR2(30) := 'NUMBER';
  c_col_data_type_date CONSTANT VARCHAR2(30) := 'DATE';
  
  c_display_column CONSTANT VARCHAR2(30) := 'DISPLAY';
  c_row_highlight CONSTANT VARCHAR2(30) := 'ROW_HIGHLIGHT';
  c_column_highlight CONSTANT VARCHAR2(30) := 'COLUMN_HIGHLICHT';
  c_break_definition CONSTANT VARCHAR2(30) := 'BREAK_DEF';
  c_aggregate_column CONSTANT VARCHAR2(30) := 'AGGREGATE';
  
  c_apex_date_fmt CONSTANT VARCHAR2(30) := 'YYYYMMDDHH24MISS';
  

/* Global Variables */
 
  -- runtime data
  g_apex_ir_info apexir_xlsx_types_pkg.t_apex_ir_info;
  g_xlsx_options apexir_xlsx_types_pkg.t_xlsx_options;
  g_col_settings apexir_xlsx_types_pkg.t_apex_ir_cols;
  g_row_highlights apexir_xlsx_types_pkg.t_apex_ir_highlights;
  g_col_highlights apexir_xlsx_types_pkg.t_apex_ir_highlights;
  g_current_row PLS_INTEGER := 1;
  g_cursor_info apexir_xlsx_types_pkg.t_cursor_info;
  g_sql_columns apexir_xlsx_types_pkg.t_sql_col_infos;
  g_nls_numeric_characters VARCHAR2(2);

/* Support Procedures */

  PROCEDURE get_report_title
  AS
  BEGIN
    SELECT CASE
             WHEN rpt.report_name IS NOT NULL THEN
               ir.region_name || ' - ' || rpt.report_name
             ELSE
               ir.region_name
           END report_title
      INTO g_apex_ir_info.report_title
      FROM apex_application_page_ir ir JOIN apex_application_page_ir_rpt rpt
             ON ir.application_id = rpt.application_id
            AND ir.page_id = rpt.page_id
            AND ir.interactive_report_id = rpt.interactive_report_id
     WHERE ir.application_id = g_apex_ir_info.application_id
       AND ir.page_id = g_apex_ir_info.page_id
       AND rpt.base_report_id = g_apex_ir_info.base_report_id
       AND rpt.session_id = g_apex_ir_info.session_id
    ;
  END get_report_title;

  FUNCTION replace_substitutions(p_data IN VARCHAR2, p_substitution IN VARCHAR2)
    RETURN VARCHAR2
  AS
    l_retval VARCHAR2(4000) := p_data;
    l_full_sub VARCHAR2(4000) := '&' || p_substitution || '.';
  BEGIN
    IF INSTR(p_data, l_full_sub) > 0 THEN
      l_retval := REPLACE(l_retval, l_full_sub, v(p_substitution));
    END IF;
    RETURN l_retval;
  END replace_substitutions;

  PROCEDURE get_std_columns
  AS
    col_rec apexir_xlsx_types_pkg.t_apex_ir_col;
  BEGIN
    -- These column names are static defined, used as reference
    FOR rec IN ( SELECT column_alias, report_label, display_text_as, format_mask
                   FROM APEX_APPLICATION_PAGE_IR_COL
                  WHERE page_id = g_apex_ir_info.page_id
                    AND application_id = g_apex_ir_info.application_id
                    AND region_id = g_apex_ir_info.region_id )
    LOOP
      col_rec.report_label := rec.report_label;
      col_rec.is_visible := rec.display_text_as != 'HIDDEN';
      col_rec.format_mask := replace_substitutions(rec.format_mask, 'APP_DATE_TIME_FORMAT');
      g_col_settings(rec.column_alias) := col_rec;
    END LOOP;
  END get_std_columns;


  PROCEDURE get_computations
  AS
    col_rec  apexir_xlsx_types_pkg.t_apex_ir_col;
  BEGIN
    -- computations are run-time data, therefore need base report ID and session
    FOR rec IN (SELECT computation_column_alias,computation_report_label, computation_format_mask
                  FROM apex_application_page_ir_comp comp JOIN apex_application_page_ir_rpt rpt
                         ON rpt.application_id = comp.application_id
                        AND rpt.page_id = comp.page_id
                        AND rpt.report_id = comp.report_id
                 WHERE rpt.application_id = g_apex_ir_info.application_id
                   AND rpt.page_id = g_apex_ir_info.page_id
                   AND rpt.base_report_id = g_apex_ir_info.base_report_id
                   AND rpt.session_id = g_apex_ir_info.session_id)
    LOOP
      col_rec.report_label := rec.computation_report_label;
      col_rec.is_visible := TRUE;
      col_rec.format_mask := replace_substitutions(rec.computation_format_mask, 'APP_DATE_TIME_FORMAT');
      g_col_settings(rec.computation_column_alias) := col_rec;
    END LOOP;
  END get_computations;

  FUNCTION transform_aggregate (p_column_value IN VARCHAR2, p_aggregate_name IN VARCHAR2)
    RETURN apexir_xlsx_types_pkg.t_apex_ir_aggregate
  AS
    l_retval apexir_xlsx_types_pkg.t_apex_ir_aggregate;
    l_vc_arr2 apex_application_global.vc_arr2;
  BEGIN
    IF p_column_value IS NOT NULL THEN
      g_apex_ir_info.active_aggregates(p_aggregate_name) := TRUE;
      l_vc_arr2 := apex_util.string_to_table(p_column_value);
      FOR i IN 1..l_vc_arr2.COUNT LOOP
        l_retval(l_vc_arr2(i)) := i;
      END LOOP;
    END IF;
    RETURN l_retval;
  END transform_aggregate;

  PROCEDURE get_aggregates
  AS
    l_avg_cols  apex_application_page_ir_rpt.avg_columns_on_break%TYPE;
    l_break_on  apex_application_page_ir_rpt.break_enabled_on%TYPE;
    l_count_cols  apex_application_page_ir_rpt.count_columns_on_break%TYPE;
    l_count_distinct_cols  apex_application_page_ir_rpt.count_distnt_col_on_break%TYPE;
    l_max_cols  apex_application_page_ir_rpt.max_columns_on_break%TYPE;
    l_median_cols  apex_application_page_ir_rpt.median_columns_on_break%TYPE;
    l_min_cols  apex_application_page_ir_rpt.min_columns_on_break%TYPE;
    l_sum_cols  apex_application_page_ir_rpt.sum_columns_on_break%TYPE;
    l_all_aggregates VARCHAR2(32767);

    l_cur_col  VARCHAR2(30);
    l_aggregates apexir_xlsx_types_pkg.t_apex_ir_aggregates;
    l_aggregate_col_offset PLS_INTEGER;
    l_col_aggregates apexir_xlsx_types_pkg.t_apex_ir_col_aggregates;
    
  BEGIN
    -- First get run-time settings for aggregate infos
    SELECT break_enabled_on,
           sum_columns_on_break,
           avg_columns_on_break,
           max_columns_on_break,
           min_columns_on_break,
           median_columns_on_break,
           count_columns_on_break,
           count_distnt_col_on_break,
           sum_columns_on_break || 
           avg_columns_on_break || 
           max_columns_on_break || 
           min_columns_on_break || 
           median_columns_on_break || 
           count_columns_on_break ||
           count_distnt_col_on_break AS all_aggregates
      INTO l_break_on,
           l_sum_cols,
           l_avg_cols,
           l_max_cols,
           l_min_cols,
           l_median_cols,
           l_count_cols,
           l_count_distinct_cols,
           l_all_aggregates
      FROM apex_application_page_ir_rpt
     WHERE application_id = g_apex_ir_info.application_id
       AND page_id = g_apex_ir_info.page_id
       AND base_report_id = g_apex_ir_info.base_report_id
       AND session_id = g_apex_ir_info.session_id;

    l_aggregates.sum_cols := transform_aggregate(l_sum_cols, 'Sum');
    l_aggregates.avg_cols := transform_aggregate(l_avg_cols, 'Average');
    l_aggregates.max_cols := transform_aggregate(l_max_cols, 'Maximum');
    l_aggregates.min_cols := transform_aggregate(l_min_cols, 'Minimum');
    l_aggregates.median_cols := transform_aggregate(l_median_cols, 'Median');
    l_aggregates.count_cols := transform_aggregate(l_count_cols, 'Count');
    l_aggregates.count_distinct_cols := transform_aggregate(l_count_distinct_cols, 'Unique Count');
    
    -- Loop through all selected columns and apply settings
    l_cur_col := g_col_settings.FIRST();
    WHILE (l_cur_col IS NOT NULL)
    LOOP
      IF l_break_on IS NOT NULL AND INSTR(l_break_on, l_cur_col) > 0 THEN
        g_col_settings(l_cur_col).is_break_col := TRUE;
        IF g_col_settings(l_cur_col).is_visible THEN
          g_apex_ir_info.aggregate_type_disp_column := g_apex_ir_info.aggregate_type_disp_column + 1;
          g_apex_ir_info.final_sql := g_apex_ir_info.final_sql || l_cur_col || ' || ';
        END IF;
      END IF;
      l_aggregate_col_offset := g_apex_ir_info.aggregates_offset; -- reset offset to global offset for every new column
      l_col_aggregates.delete;
      IF INSTR(l_all_aggregates, l_cur_col) > 0 THEN
        IF l_aggregates.sum_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Sum') := l_aggregate_col_offset + l_aggregates.sum_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.sum_cols.count;
        END IF;
        IF l_aggregates.avg_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Average') := l_aggregate_col_offset + l_aggregates.avg_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.avg_cols.count;
        END IF;
        IF l_aggregates.max_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Maximum') := l_aggregate_col_offset + l_aggregates.max_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.max_cols.count;
        END IF;
        IF l_aggregates.min_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Minimum') := l_aggregate_col_offset + l_aggregates.min_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.min_cols.count;
        END IF;
        IF l_aggregates.median_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Median') := l_aggregate_col_offset + l_aggregates.median_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.median_cols.count;
        END IF;
        IF l_aggregates.count_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Count') := l_aggregate_col_offset + l_aggregates.count_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.count_cols.count;
        END IF;
        IF l_aggregates.count_distinct_cols.EXISTS(l_cur_col) THEN
          l_col_aggregates('Unique Count') := l_aggregate_col_offset + l_aggregates.count_distinct_cols(l_cur_col);
          l_aggregate_col_offset := l_aggregate_col_offset + l_aggregates.count_distinct_cols.count;
        END IF;
        g_col_settings(l_cur_col).aggregate_col_nums := l_col_aggregates;
      END IF;
      l_cur_col := g_col_settings.next(l_cur_col);
    END LOOP;
    IF l_break_on IS NOT NULL THEN
      g_apex_ir_info.final_sql := ', ' || RTRIM(g_apex_ir_info.final_sql, '|| ') || ' AS ' || c_break_definition;
    END IF;
  END get_aggregates;

  PROCEDURE get_highlights
  AS
    col_rec apexir_xlsx_types_pkg.t_apex_ir_highlight;
    hl_num NUMBER := 0;
  BEGIN
    FOR rec IN (SELECT CASE
                         WHEN cond.highlight_row_color IS NOT NULL OR cond.highlight_row_font_color IS NOT NULL
                           THEN NULL
                         ELSE cond.condition_column_name
                       END condition_column_name,
                       REPLACE (cond.condition_sql, '#APXWS_EXPR#', '''' || cond.condition_expression || '''') test_sql,
                       cond.condition_name,
                       REPLACE(COALESCE(cond.highlight_row_color, cond.highlight_cell_color), '#') bg_color,
                       REPLACE(COALESCE(cond.highlight_row_font_color, cond.highlight_cell_font_color), '#') font_color
                  FROM apex_application_page_ir_cond cond JOIN apex_application_page_ir_rpt r
                         ON r.application_id = cond.application_id
                        AND r.page_id = cond.page_id
                        AND r.report_id = cond.report_id
                 WHERE cond.application_id = g_apex_ir_info.application_id
                   AND cond.page_id = g_apex_ir_info.page_id
                   AND cond.condition_type = 'Highlight'
                   AND cond.condition_enabled = 'Yes'
                   AND r.base_report_id = g_apex_ir_info.base_report_id
                   AND r.session_id = g_apex_ir_info.session_id
                   AND ( cond.highlight_row_color IS NOT NULL
                      OR cond.highlight_row_font_color IS NOT NULL
                      OR cond.highlight_cell_color IS NOT NULL
                      OR cond.highlight_cell_font_color IS NOT NULL
                       )
                ORDER BY cond.condition_column_name, cond.highlight_sequence
               )
    LOOP
      hl_num := hl_num + 1;
      col_rec.bg_color := rec.bg_color;
      col_rec.font_color := rec.font_color;
      col_rec.highlight_name := rec.condition_name;
      col_rec.highlight_sql := REPLACE(rec.test_sql, '#APXWS_HL_ID#', 1);
      col_rec.affected_column := rec.condition_column_name;
      IF rec.condition_column_name IS NOT NULL AND g_col_settings.EXISTS(rec.condition_column_name) THEN
        g_col_highlights('HL_' || to_char(hl_num)) := col_rec;
      ELSE
        g_row_highlights('HL_' || to_char(hl_num)) := col_rec;
      END IF;
      g_apex_ir_info.final_sql := g_apex_ir_info.final_sql || ', ' || col_rec.highlight_sql || ' AS HL_' || to_char(hl_num);
    END LOOP;
  END get_highlights;
  
  PROCEDURE process_row_highlights (p_fetched_row_cnt IN PLS_INTEGER)
  AS
    l_cur_highlight VARCHAR2(30);
  BEGIN
    l_cur_highlight := g_row_highlights.FIRST();
    WHILE l_cur_highlight IS NOT NULL LOOP
      dbms_sql.COLUMN_VALUE( g_cursor_info.cursor_id, g_row_highlights(l_cur_highlight).col_num, g_cursor_info.num_tab );
      FOR i IN 0 .. p_fetched_row_cnt - 1 LOOP
        IF (g_cursor_info.num_tab(i + g_cursor_info.num_tab.FIRST()) IS NOT NULL) THEN
          xlsx_builder_pkg.set_row( p_row => g_current_row + i + g_cursor_info.break_rows(i)
                                  , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                         , p_rgb => g_row_highlights(l_cur_highlight).font_color
                                                                         )
                                  , p_fillId => xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                         , p_fgRGB => g_row_highlights(l_cur_highlight).bg_color
                                                                         )
                                  );
        END IF;
      END LOOP;
      g_cursor_info.num_tab.DELETE;
      l_cur_highlight := g_row_highlights.next(l_cur_highlight);
    END LOOP;
  END process_row_highlights;

  PROCEDURE get_settings
  AS
  BEGIN
    SELECT VALUE
      INTO g_nls_numeric_characters
      FROM v$nls_parameters
     where parameter = 'NLS_NUMERIC_CHARACTERS';
    
   SELECT VALUE
     INTO g_xlsx_options.default_date_format
     FROM v$nls_parameters
    WHERE parameter = 'NLS_DATE_FORMAT';

    
    get_report_title;
    get_std_columns;
    get_computations;
    IF g_xlsx_options.show_aggregates THEN
      get_aggregates;
    END IF;
    IF g_xlsx_options.process_highlights THEN
      get_highlights;
    END IF;
  END get_settings;

  PROCEDURE fix_borders
  AS
  BEGIN
    FOR i IN 2..g_xlsx_options.display_column_count LOOP
    /* strange fix for borders... */
      xlsx_builder_pkg.cell( p_col => i
                           , p_row => g_current_row
                           , p_value => to_char(NULL)
                           , p_borderId => xlsx_builder_pkg.get_border('thin', 'thin', 'thin', 'thin')
                           , p_sheet => g_xlsx_options.sheet
                           );
    END LOOP;
  END fix_borders;

  PROCEDURE print_filter_header
  AS
    l_condition_display VARCHAR2(4100);
  BEGIN
    FOR rec IN (SELECT condition_type,
                       cond.condition_name,
                       condition_column_name,
                       cond.condition_operator,
                       cond.condition_expression,
                       cond.condition_expression2,
                       cond.condition_display,
                       r.base_report_id, r.report_id
                  FROM apex_application_page_ir_cond cond JOIN apex_application_page_ir_rpt r
                         ON r.application_id = cond.application_id
                        AND r.page_id = cond.page_id
                        AND r.report_id = cond.report_id
                 WHERE cond.application_id = g_apex_ir_info.application_id
                   AND cond.page_id = g_apex_ir_info.page_id
                   AND r.base_report_id = g_apex_ir_info.base_report_id
                   AND r.session_id = g_apex_ir_info.session_id
                   AND cond.condition_type IN ('Search', 'Filter')
                   AND cond.condition_enabled = 'Yes'
                )
    LOOP
      IF rec.condition_type = 'Search' OR
         (rec.condition_type = 'Filter' AND rec.condition_column_name IS NULL)
      THEN
        l_condition_display := rec.condition_name;
      ELSE
        l_condition_display := REPLACE( rec.condition_display,'#APXWS_COL_NAME#'
                                      , g_col_settings(rec.condition_column_name).report_label
                                      );
        l_condition_display := REPLACE(l_condition_display, '#APXWS_OP_NAME#', rec.condition_operator);
        l_condition_display := REPLACE(l_condition_display, '#APXWS_AND#', 'and');
        IF INSTR(l_condition_display, '#APXWS_EXPR_DATE#') > 0 OR INSTR(l_condition_display, '#APXWS_EXPR2_DATE#') > 0 THEN
          l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR_DATE#', TO_CHAR(TO_DATE(rec.condition_expression, c_apex_date_fmt)));
          l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR2_DATE#', TO_CHAR(TO_DATE(rec.condition_expression2, c_apex_date_fmt)));
        END IF;
        
        l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR#', rec.condition_expression);
        l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR_NAME#', rec.condition_expression);
        l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR_NUMBER#', rec.condition_expression);
        l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR2#', rec.condition_expression2);
        l_condition_display := REPLACE(l_condition_display, '#APXWS_EXPR2_NAME#', rec.condition_expression2);
      END IF;
      xlsx_builder_pkg.mergecells( p_tl_col => 1
                                 , p_tl_row => g_current_row
                                 , p_br_col => g_xlsx_options.display_column_count
                                 , p_br_row => g_current_row
                                 , p_sheet => g_xlsx_options.sheet
                                 );
      xlsx_builder_pkg.cell( p_col => 1
                           , p_row => g_current_row
                           , p_value => l_condition_display
                           , p_fillId => xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                  , p_fgRGB => 'FFF8DC'
                                                                  )
                           , p_alignment => xlsx_builder_pkg.get_alignment( p_vertical => 'center'
                                                                          , p_horizontal => 'center'
                                                                          )
                           , p_borderId => xlsx_builder_pkg.get_border('thin', 'thin', 'thin', 'thin')
                           , p_sheet => g_xlsx_options.sheet );
      fix_borders;
      g_current_row := g_current_row + 1;
    END LOOP;
  END print_filter_header;

  PROCEDURE print_header
  AS
    l_cur_hl_name VARCHAR2(30);
  BEGIN
    IF g_xlsx_options.show_title THEN
      xlsx_builder_pkg.mergecells( p_tl_col => 1
                                 , p_tl_row => g_current_row
                                 , p_br_col => g_xlsx_options.display_column_count
                                 , p_br_row => g_current_row
                                 , p_sheet => g_xlsx_options.sheet
                                 );
      xlsx_builder_pkg.cell( p_col => 1
                           , p_row => g_current_row
                           , p_value => g_apex_ir_info.report_title
                           , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                  , p_fontsize => 14
                                                                  , p_bold => TRUE
                                                                  )
                           , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                  , p_fgRGB => 'FFF8DC'
                                                                  )
                          , p_alignment => xlsx_builder_pkg.get_alignment( p_vertical => 'center'
                                                                         , p_horizontal => 'center'
                                                                         )
                          , p_borderId => xlsx_builder_pkg.get_border('thin', 'thin', 'thin', 'thin')
                          , p_sheet => g_xlsx_options.sheet
                          );
      fix_borders;
      g_current_row := g_current_row + 1;
    END IF;
    IF g_xlsx_options.show_filters THEN
      print_filter_header;
    END IF;
    IF g_xlsx_options.show_highlights THEN
      l_cur_hl_name := g_row_highlights.FIRST();
      WHILE (l_cur_hl_name IS NOT NULL) LOOP
        xlsx_builder_pkg.mergecells( p_tl_col => 1
                                   , p_tl_row => g_current_row
                                   , p_br_col => g_xlsx_options.display_column_count
                                   , p_br_row => g_current_row
                                   , p_sheet => g_xlsx_options.sheet
                                   );
        xlsx_builder_pkg.cell( p_col => 1
                             , p_row => g_current_row
                             , p_value => g_row_highlights(l_cur_hl_name).highlight_name
                             , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                    , p_rgb => g_row_highlights(l_cur_hl_name).font_color
                                                                    )
                             , p_fillId => xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                    , p_fgRGB => g_row_highlights(l_cur_hl_name).bg_color
                                                                    )
                             , p_alignment => xlsx_builder_pkg.get_alignment( p_vertical => 'center'
                                                                            , p_horizontal => 'center'
                                                                            )
                             , p_borderId => xlsx_builder_pkg.get_border('thin', 'thin', 'thin', 'thin')
                             , p_sheet => g_xlsx_options.sheet );
        fix_borders;
        g_current_row := g_current_row + 1;
        l_cur_hl_name := g_row_highlights.next(l_cur_hl_name);
      END LOOP;
      l_cur_hl_name := g_col_highlights.FIRST();
      WHILE (l_cur_hl_name IS NOT NULL) LOOP
        xlsx_builder_pkg.mergecells( p_tl_col => 1
                                   , p_tl_row => g_current_row
                                   , p_br_col => g_xlsx_options.display_column_count
                                   , p_br_row => g_current_row
                                   , p_sheet => g_xlsx_options.sheet
                                   );
        xlsx_builder_pkg.cell( p_col => 1
                             , p_row => g_current_row
                             , p_value => g_col_highlights(l_cur_hl_name).highlight_name
                             , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                    , p_rgb => g_col_highlights(l_cur_hl_name).font_color
                                                                    )
                             , p_fillId => xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                    , p_fgRGB => g_col_highlights(l_cur_hl_name).bg_color
                                                                    )
                             , p_alignment => xlsx_builder_pkg.get_alignment( p_vertical => 'center'
                                                                            , p_horizontal => 'center'
                                                                            )
                             , p_borderId => xlsx_builder_pkg.get_border('thin', 'thin', 'thin', 'thin')
                             , p_sheet => g_xlsx_options.sheet
                             );
        fix_borders;
        g_current_row := g_current_row + 1;        
        l_cur_hl_name := g_col_highlights.next(l_cur_hl_name);
      END LOOP;
    END IF;
    g_current_row := g_current_row + 1; --add additional row
  END print_header;

  PROCEDURE prepare_cursor
  AS
    l_desc_tab dbms_sql.desc_tab2;
    l_cur_col_highlight apexir_xlsx_types_pkg.t_apex_ir_highlight;
  BEGIN
    -- Split sql query on first from and inject highlight conditions
    g_apex_ir_info.final_sql := SUBSTR(g_apex_ir_info.report_definition.sql_query, 1, INSTR(UPPER(g_apex_ir_info.report_definition.sql_query), ' FROM')) 
                             || g_apex_ir_info.final_sql
                             || SUBSTR(apex_plugin_util.replace_substitutions(g_apex_ir_info.report_definition.sql_query), INSTR(UPPER(g_apex_ir_info.report_definition.sql_query), ' FROM'));

    g_cursor_info.cursor_id := dbms_sql.open_cursor;
    dbms_sql.parse( g_cursor_info.cursor_id, g_apex_ir_info.final_sql, dbms_sql.NATIVE );
    dbms_sql.describe_columns2( g_cursor_info.cursor_id, g_cursor_info.column_count, l_desc_tab );
    
    /* Bind values from IR structure*/
    FOR i IN 1..g_apex_ir_info.report_definition.binds.count LOOP
      IF g_apex_ir_info.report_definition.binds(i).NAME = 'REQUEST' THEN
        dbms_sql.bind_variable( g_cursor_info.cursor_id, g_apex_ir_info.report_definition.binds(i).NAME, g_apex_ir_info.request);
      ELSE
        dbms_sql.bind_variable( g_cursor_info.cursor_id, g_apex_ir_info.report_definition.binds(i).name, g_apex_ir_info.report_definition.binds(i).value);
      END IF;
    END LOOP;

    /* Amend column settings*/    
    FOR c IN 1 .. g_cursor_info.column_count LOOP
      g_sql_columns(c).col_name := l_desc_tab(c).col_name;
      CASE
        WHEN l_desc_tab( c ).col_type IN ( 2, 100, 101 ) THEN
          dbms_sql.define_array( g_cursor_info.cursor_id, c, g_cursor_info.num_tab, c_bulk_size, 1 );
          g_sql_columns(c).col_data_type := c_col_data_type_num;
        WHEN l_desc_tab( c ).col_type IN ( 12, 178, 179, 180, 181 , 231 ) THEN
          dbms_sql.define_array( g_cursor_info.cursor_id, c, g_cursor_info.date_tab, c_bulk_size, 1 );
          g_sql_columns(c).col_data_type := c_col_data_type_date;
        WHEN l_desc_tab( c ).col_type IN ( 1, 8, 9, 96, 112 ) THEN
          dbms_sql.define_array( g_cursor_info.cursor_id, c, g_cursor_info.vc_tab, c_bulk_size, 1 );
          g_sql_columns(c).col_data_type := c_col_data_type_vc;
        ELSE
          NULL;
      END CASE;

      IF g_col_settings.exists(l_desc_tab(c).col_name) THEN
        IF g_col_settings(l_desc_tab(c).col_name).is_visible THEN -- remove hidden cols
          g_xlsx_options.display_column_count := g_xlsx_options.display_column_count + 1; -- count number of displayed columns
          g_sql_columns(c).is_displayed := TRUE;
          g_sql_columns(c).col_type := c_display_column;
          g_col_settings(l_desc_tab(c).col_name).sql_col_num := c; -- column in SQL
          g_col_settings(l_desc_tab(c).col_name).display_column := g_xlsx_options.display_column_count; -- column in spreadsheet
        END IF;
      ELSIF g_row_highlights.EXISTS(l_desc_tab(c).col_name) THEN
        g_row_highlights(l_desc_tab(c).col_name).col_num := c;
        g_sql_columns(c).col_type := c_row_highlight;
      ELSIF g_col_highlights.EXISTS(l_desc_tab(c).col_name) THEN
        g_col_highlights(l_desc_tab(c).col_name).col_num := c;
        g_sql_columns(c).col_type := c_column_highlight;
        l_cur_col_highlight := g_col_highlights(l_desc_tab(c).col_name);
        g_col_settings(l_cur_col_highlight.affected_column).highlight_conds(l_desc_tab(c).col_name) := l_cur_col_highlight;
      ELSIF l_desc_tab(c).col_name = c_break_definition THEN
        g_sql_columns(c).col_type := c_break_definition;
        g_apex_ir_info.break_def_column := c;
      END IF;
    END LOOP;  
  END prepare_cursor;

  PROCEDURE print_column_headers
  AS
  BEGIN
    FOR c IN 1..g_cursor_info.column_count LOOP
      IF g_sql_columns(c).is_displayed THEN
        xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(c).col_name).display_column
                             , p_row => g_current_row
                             , p_value => REPLACE(g_col_settings(g_sql_columns(c).col_name).report_label, g_xlsx_options.original_line_break, g_xlsx_options.replace_line_break)
                             , p_alignment => CASE 
                                                WHEN g_xlsx_options.allow_wrap_text THEN NULL
                                                ELSE xlsx_builder_pkg.get_alignment(p_vertical => 'center', p_horizontal => 'center', p_wrapText => FALSE)
                                              END
                             , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                    , p_bold => TRUE
                                                                    )
                             , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                    , p_fgRGB => 'FFF8DC'
                                                                    )
                             , p_borderId => xlsx_builder_pkg.get_border('thin', 'thin', 'thin', 'thin')
                             , p_sheet => g_xlsx_options.sheet
                             );
      END IF;
    END LOOP;
    g_current_row := g_current_row + 1;
  END print_column_headers;

  FUNCTION process_col_highlights ( p_column_name IN VARCHAR2
                                  , p_fetched_row_cnt IN PLS_INTEGER
                                  )
    RETURN apexir_xlsx_types_pkg.t_apex_ir_active_hl
  AS
    l_cur_hl_name VARCHAR2(30);
    l_cur_col_highlight apexir_xlsx_types_pkg.t_apex_ir_highlight;
    retval apexir_xlsx_types_pkg.t_apex_ir_active_hl;
  BEGIN
    l_cur_hl_name := g_col_settings(p_column_name).highlight_conds.FIRST;
    WHILE (l_cur_hl_name IS NOT NULL) LOOP
      l_cur_col_highlight := g_col_settings(p_column_name).highlight_conds(l_cur_hl_name);
      dbms_sql.COLUMN_VALUE( g_cursor_info.cursor_id, l_cur_col_highlight.col_num, g_cursor_info.num_tab);
      FOR i IN 0 .. p_fetched_row_cnt - 1 LOOP
        -- highlight condition TRUE
        IF g_cursor_info.num_tab(i + g_cursor_info.num_tab.FIRST()) IS NOT NULL THEN
          -- no previous highlight condition matched
          IF NOT retval.EXISTS(i) THEN
            retval(i) := l_cur_col_highlight;
          END IF;
        END IF;
      END LOOP;
      g_cursor_info.num_tab.DELETE;
      l_cur_hl_name := g_col_settings(p_column_name).highlight_conds.next(l_cur_hl_name);
    END LOOP;
    RETURN retval;
  END process_col_highlights;

  PROCEDURE print_aggregates ( p_column_name IN VARCHAR2
                             , p_fetched_row_cnt IN PLS_INTEGER
                             )
  AS
    l_aggregate_values dbms_sql.number_table;
    l_cur_aggregate_name VARCHAR2(30);
    l_aggregate_offset PLS_INTEGER := 0;
  BEGIN
    -- fixed order for aggregates, same as occurence in t_apexir_col type
    l_cur_aggregate_name := g_apex_ir_info.active_aggregates.FIRST();
    WHILE (l_cur_aggregate_name IS NOT NULL) LOOP
      IF g_col_settings(p_column_name).aggregate_col_nums.EXISTS(l_cur_aggregate_name) THEN
        dbms_sql.COLUMN_VALUE( g_cursor_info.cursor_id
                             , g_col_settings(p_column_name).aggregate_col_nums(l_cur_aggregate_name)
                             , l_aggregate_values
                             );
        FOR i IN 0 .. p_fetched_row_cnt - 1 loop
          IF g_cursor_info.break_rows(i + 1) != g_cursor_info.break_rows(i) THEN
            xlsx_builder_pkg.cell( p_col => g_col_settings(p_column_name).display_column
                                 , p_row => g_current_row + i - 1 + g_cursor_info.break_rows(i + 1) + l_aggregate_offset
                                 , p_value => l_aggregate_values( i + l_aggregate_values.FIRST() )
                                 , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                        , p_bold => TRUE
                                                                        )
                                 , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                        , p_fgRGB => 'FFF8DC'
                                                                        )
                                 , p_numFmtId => xlsx_builder_pkg.get_numFmt(xlsx_builder_pkg.OraNumFmt2Excel(g_col_settings(p_column_name).format_mask))
                                 , p_sheet => g_xlsx_options.sheet
                                 );
          END IF;
        END LOOP;
      END IF;
      l_aggregate_offset := l_aggregate_offset + 1;
      l_cur_aggregate_name := g_apex_ir_info.active_aggregates.NEXT(l_cur_aggregate_name);
      l_aggregate_values.DELETE;
    END LOOP;
  END print_aggregates;

  PROCEDURE print_num_column ( p_column_position IN PLS_INTEGER
                             , p_fetched_row_cnt IN PLS_INTEGER
                             , p_active_highlights IN apexir_xlsx_types_pkg.t_apex_ir_active_hl
                             )
  AS
  BEGIN
    dbms_sql.COLUMN_VALUE( g_cursor_info.cursor_id, p_column_position, g_cursor_info.num_tab );
    FOR i IN 0 .. p_fetched_row_cnt - 1 loop
      xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(p_column_position).col_name).display_column
                           , p_row => g_current_row + i + g_cursor_info.break_rows(i)
                           , p_value => g_cursor_info.num_tab( i + g_cursor_info.num_tab.FIRST() )
                           , p_numFmtId => xlsx_builder_pkg.get_numFmt(xlsx_builder_pkg.OraNumFmt2Excel(g_col_settings(g_sql_columns(p_column_position).col_name).format_mask))
                           , p_fontId => CASE
                                           WHEN p_active_highlights.EXISTS(i) AND p_active_highlights(i).font_color IS NOT NULL THEN
                                             xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                      , p_rgb => p_active_highlights(i).font_color
                                                                      )
                                           ELSE NULL
                                         END
                           , p_fillId => CASE
                                           WHEN p_active_highlights.EXISTS(i) AND p_active_highlights(i).bg_color IS NOT NULL THEN
                                             xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                      , p_fgRGB => p_active_highlights(i).bg_color
                                                                      )
                                           ELSE NULL
                                         END
                           , p_sheet => g_xlsx_options.sheet
                           );
      IF g_xlsx_options.show_aggregates AND g_apex_ir_info.aggregate_type_disp_column != g_col_settings(g_sql_columns(p_column_position).col_name).display_column THEN
        IF i = p_fetched_row_cnt OR g_cursor_info.break_rows(i + 1) != g_cursor_info.break_rows(i) THEN
          FOR j IN 1..g_apex_ir_info.active_aggregates.count LOOP
            xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(p_column_position).col_name).display_column
                                 , p_row => g_current_row + i + g_cursor_info.break_rows(i) + j
                                 , p_value => CASE
                                                WHEN g_col_settings(g_sql_columns(p_column_position).col_name).is_break_col
                                                  THEN g_cursor_info.num_tab( i + g_cursor_info.num_tab.FIRST() )
                                                ELSE NULL
                                              END
                                 , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                        , p_bold => TRUE
                                                                        )
                                 , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                        , p_fgRGB => 'FFF8DC'
                                                                        )
                                 , p_sheet => g_xlsx_options.sheet
                                 );
          END LOOP;
        END IF;
      END IF;
    END loop;
    IF g_xlsx_options.show_aggregates THEN
      print_aggregates(g_sql_columns(p_column_position).col_name, p_fetched_row_cnt);
    END IF;
    g_cursor_info.num_tab.DELETE;
  END print_num_column;

  PROCEDURE print_date_column ( p_column_position IN PLS_INTEGER
                              , p_fetched_row_cnt IN PLS_INTEGER
                              , p_active_highlights IN apexir_xlsx_types_pkg.t_apex_ir_active_hl
                              )
  AS
  BEGIN
    dbms_sql.COLUMN_VALUE( g_cursor_info.cursor_id, p_column_position, g_cursor_info.date_tab );
    FOR i IN 0 .. p_fetched_row_cnt - 1 loop
      xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(p_column_position).col_name).display_column
                           , p_row => g_current_row + i + g_cursor_info.break_rows(i)
                           , p_value => g_cursor_info.date_tab( i + g_cursor_info.date_tab.FIRST() )
                           , p_numFmtId => xlsx_builder_pkg.get_numFmt(xlsx_builder_pkg.OraFmt2Excel(COALESCE(g_col_settings(g_sql_columns(p_column_position).col_name).format_mask, g_xlsx_options.default_date_format)))
                           , p_fontId => CASE
                                           WHEN p_active_highlights.EXISTS(i) AND p_active_highlights(i).font_color IS NOT NULL THEN
                                             xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                      , p_rgb => p_active_highlights(i).font_color
                                                                      )
                                           ELSE NULL
                                         END
                           , p_fillId => CASE
                                           WHEN p_active_highlights.EXISTS(i) AND p_active_highlights(i).bg_color IS NOT NULL THEN
                                             xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                      , p_fgRGB => p_active_highlights(i).bg_color
                                                                      )
                                           ELSE NULL
                                         END
                           , p_sheet => g_xlsx_options.sheet
                           );
      IF g_xlsx_options.show_aggregates AND g_apex_ir_info.aggregate_type_disp_column != g_col_settings(g_sql_columns(p_column_position).col_name).display_column THEN
        IF i = p_fetched_row_cnt OR g_cursor_info.break_rows(i + 1) != g_cursor_info.break_rows(i) THEN
          FOR j IN 1..g_apex_ir_info.active_aggregates.count LOOP
            xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(p_column_position).col_name).display_column
                                 , p_row => g_current_row + i + g_cursor_info.break_rows(i) + j
                                 , p_value => CASE
                                                WHEN g_col_settings(g_sql_columns(p_column_position).col_name).is_break_col
                                                  THEN g_cursor_info.date_tab( i + g_cursor_info.date_tab.FIRST() )
                                                ELSE NULL
                                              END
                                 , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                        , p_bold => TRUE
                                                                        )
                                 , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                        , p_fgRGB => 'FFF8DC'
                                                                        )
                                 , p_sheet => g_xlsx_options.sheet
                                 );
          END LOOP;
        END IF;
      END IF;
    END LOOP;
    IF g_xlsx_options.show_aggregates THEN
      print_aggregates(g_sql_columns(p_column_position).col_name, p_fetched_row_cnt);
    END IF;
    g_cursor_info.date_tab.DELETE;
  END print_date_column;
  
  PROCEDURE print_vc_column ( p_column_position IN PLS_INTEGER
                            , p_fetched_row_cnt IN PLS_INTEGER
                            , p_active_highlights IN apexir_xlsx_types_pkg.t_apex_ir_active_hl
                            )
  AS
  BEGIN
    dbms_sql.COLUMN_VALUE( g_cursor_info.cursor_id, p_column_position, g_cursor_info.vc_tab );
    FOR i IN 0 .. p_fetched_row_cnt - 1 loop
      xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(p_column_position).col_name).display_column
                           , p_row => g_current_row + i + g_cursor_info.break_rows(i)
                           , p_value => REPLACE(g_cursor_info.vc_tab(i + g_cursor_info.vc_tab.FIRST()), g_xlsx_options.original_line_break, g_xlsx_options.replace_line_break)
                           , p_alignment => CASE WHEN g_xlsx_options.allow_wrap_text THEN NULL ELSE xlsx_builder_pkg.get_alignment(p_wrapText => FALSE) END
                           , p_fontId => CASE
                                           WHEN p_active_highlights.EXISTS(i) AND p_active_highlights(i).font_color IS NOT NULL THEN
                                             xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                      , p_rgb => p_active_highlights(i).font_color
                                                                      )
                                           ELSE NULL
                                         END
                           , p_fillId => CASE
                                           WHEN p_active_highlights.EXISTS(i) AND p_active_highlights(i).bg_color IS NOT NULL THEN
                                             xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                                      , p_fgRGB => p_active_highlights(i).bg_color
                                                                      )
                                           ELSE NULL
                                         END
                           , p_sheet => g_xlsx_options.sheet
                           );
      IF g_xlsx_options.show_aggregates AND g_apex_ir_info.aggregate_type_disp_column != g_col_settings(g_sql_columns(p_column_position).col_name).display_column THEN
        IF i = p_fetched_row_cnt OR g_cursor_info.break_rows(i + 1) != g_cursor_info.break_rows(i) THEN
          FOR j IN 1..g_apex_ir_info.active_aggregates.count LOOP
            xlsx_builder_pkg.cell( p_col => g_col_settings(g_sql_columns(p_column_position).col_name).display_column
                                 , p_row => g_current_row + i + g_cursor_info.break_rows(i) + j
                                 , p_value => CASE
                                                WHEN g_col_settings(g_sql_columns(p_column_position).col_name).is_break_col
                                                  THEN REPLACE(g_cursor_info.vc_tab(i + g_cursor_info.vc_tab.FIRST()), g_xlsx_options.original_line_break, g_xlsx_options.replace_line_break)
                                               ELSE NULL
                                             END
                                 , p_alignment => CASE WHEN g_xlsx_options.allow_wrap_text THEN NULL ELSE xlsx_builder_pkg.get_alignment(p_wrapText => FALSE) END
                                 , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                        , p_bold => TRUE
                                                                        )
                                , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                       , p_fgRGB => 'FFF8DC'
                                                                       )
                                , p_sheet => g_xlsx_options.sheet
                                 );
          END LOOP;
        END IF;
      END IF;
    END LOOP;
    IF g_xlsx_options.show_aggregates THEN
      print_aggregates(g_sql_columns(p_column_position).col_name, p_fetched_row_cnt);
    END IF;
    g_cursor_info.vc_tab.DELETE;
  END print_vc_column;

  PROCEDURE print_aggregate_types (p_row_offset IN PLS_INTEGER)
  AS
    l_cur_aggregate_type VARCHAR2(30);
    l_cnt PLS_INTEGER := 0;
  BEGIN
    l_cur_aggregate_type := g_apex_ir_info.active_aggregates.FIRST();
    WHILE (l_cur_aggregate_type IS NOT NULL) LOOP
      xlsx_builder_pkg.set_row( p_row => g_current_row + p_row_offset + l_cnt
                        , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                               , p_bold => true
                                                               )
                        , p_fillId => xlsx_builder_pkg.get_fill( p_patternType => 'solid'
                                                               , p_fgRGB => 'FFF8DC'
                                                               )
                        );

      xlsx_builder_pkg.cell( p_col => g_apex_ir_info.aggregate_type_disp_column
                           , p_row => g_current_row + p_row_offset + l_cnt
                           , p_value => l_cur_aggregate_type
                           , p_alignment => CASE WHEN g_xlsx_options.allow_wrap_text THEN NULL ELSE xlsx_builder_pkg.get_alignment(p_wrapText => FALSE) END
                           , p_fontId => xlsx_builder_pkg.get_font( p_name => g_xlsx_options.default_font
                                                                  , p_bold => TRUE
                                                                  )
                           , p_fillId => xlsx_builder_pkg.get_fill( p_patterntype => 'solid'
                                                                  , p_fgRGB => 'FFF8DC'
                                                                  )
                           , p_sheet => g_xlsx_options.sheet
                           );
      l_cnt := l_cnt + 1;
      l_cur_aggregate_type := g_apex_ir_info.active_aggregates.next(l_cur_aggregate_type);
    END LOOP;
  END print_aggregate_types;
  
  PROCEDURE process_break_rows (p_fetched_row_cnt IN PLS_INTEGER)
  AS
    l_cnt NUMBER := 0;
  BEGIN
    g_cursor_info.break_rows(0) := 0;
    IF g_xlsx_options.show_aggregates AND g_apex_ir_info.break_def_column IS NOT NULL THEN
      DBMS_SQL.COLUMN_VALUE( g_cursor_info.cursor_id, g_apex_ir_info.break_def_column, g_cursor_info.vc_tab);
      FOR i IN 2..p_fetched_row_cnt LOOP
        IF g_cursor_info.vc_tab(i) != g_cursor_info.vc_tab(i-1) THEN
          print_aggregate_types(i - 1 + l_cnt);
          l_cnt := l_cnt + g_apex_ir_info.active_aggregates.count;
        END IF;
        g_cursor_info.break_rows(i - 1) := l_cnt;
      END LOOP;
      g_cursor_info.vc_tab.DELETE;
    ELSE
      FOR i IN 2..p_fetched_row_cnt LOOP
        g_cursor_info.break_rows(i - 1) := l_cnt;
      END LOOP;
    END IF;
    g_cursor_info.break_rows(p_fetched_row_cnt) := l_cnt + g_apex_ir_info.active_aggregates.count;
    print_aggregate_types(p_fetched_row_cnt + l_cnt);
  END process_break_rows;

  PROCEDURE print_data
  AS
    l_cur_col_name VARCHAR2(4000);
    l_fetched_row_cnt PLS_INTEGER;
    l_active_col_highlights apexir_xlsx_types_pkg.t_apex_ir_active_hl;
  BEGIN
    l_fetched_row_cnt := dbms_sql.execute( g_cursor_info.cursor_id );
    LOOP
      l_fetched_row_cnt := dbms_sql.fetch_rows( g_cursor_info.cursor_id );
      IF l_fetched_row_cnt > 0 THEN
        -- new calculation for every bulk set
        process_break_rows( p_fetched_row_cnt => l_fetched_row_cnt ); 
        process_row_highlights( p_fetched_row_cnt => l_fetched_row_cnt );
        FOR c IN 1..g_cursor_info.column_count LOOP
          IF g_sql_columns(c).is_displayed THEN
            -- next display column, empty active highlights
            l_active_col_highlights.DELETE;
            -- check if highlight processing is enabled and column has highlights attached
            IF g_xlsx_options.process_highlights AND
               g_col_settings(g_sql_columns(c).col_name).highlight_conds.count() > 0
            THEN
              l_active_col_highlights := process_col_highlights( p_column_name => g_sql_columns(c).col_name
                                                               , p_fetched_row_cnt => l_fetched_row_cnt
                                                               );
            END IF;
            
            -- now create the cells
            CASE
              WHEN g_sql_columns(c).col_data_type = c_col_data_type_num THEN
                print_num_column( p_column_position => c
                                , p_fetched_row_cnt => l_fetched_row_cnt
                                , p_active_highlights => l_active_col_highlights
                                );
              WHEN g_sql_columns(c).col_data_type = c_col_data_type_date THEN
                print_date_column( p_column_position => c
                                 , p_fetched_row_cnt => l_fetched_row_cnt
                                 , p_active_highlights => l_active_col_highlights
                                 );
              WHEN g_sql_columns(c).col_data_type = c_col_data_type_vc THEN
                print_vc_column( p_column_position => c
                               , p_fetched_row_cnt => l_fetched_row_cnt
                               , p_active_highlights => l_active_col_highlights
                               );
              ELSE NULL; -- unsupported data type
            END CASE;
          END IF;
        END LOOP;  
      END IF;
      EXIT WHEN l_fetched_row_cnt != c_bulk_size;
      g_current_row := g_current_row + l_fetched_row_cnt;
    END LOOP;
    dbms_sql.close_cursor( g_cursor_info.cursor_id );
  END print_data;
  
/* Main Function */

  FUNCTION apexir2sheet
    ( p_ir_region_id NUMBER
    , p_app_id NUMBER := NV('APP_ID')
    , p_ir_page_id NUMBER := NV('APP_PAGE_ID')
    , p_ir_session_id NUMBER := NV('SESSION')
    , p_ir_request VARCHAR2 := V('REQUEST')
    , p_column_headers BOOLEAN := TRUE
    , p_aggregates IN BOOLEAN := TRUE
    , p_process_highlights IN BOOLEAN := TRUE
    , p_show_report_title IN BOOLEAN := TRUE
    , p_show_filters IN BOOLEAN := TRUE
    , p_show_highlights IN BOOLEAN := TRUE
    , p_original_line_break IN VARCHAR2 := '<br />'
    , p_replace_line_break IN VARCHAR2 := chr(13) || chr(10)
    , p_append_date IN BOOLEAN := TRUE
    )
  RETURN apexir_xlsx_types_pkg.t_returnvalue
  AS
    l_retval apexir_xlsx_types_pkg.t_returnvalue;
  BEGIN
    -- IR infos
    g_apex_ir_info.application_id := p_app_id;
    g_apex_ir_info.page_id := p_ir_page_id;
    g_apex_ir_info.session_id := p_ir_session_id;
    g_apex_ir_info.region_id := p_ir_region_id;
    g_apex_ir_info.request := p_ir_request;
    g_apex_ir_info.base_report_id := apex_ir.get_last_viewed_report_id(p_page_id => g_apex_ir_info.page_id, p_region_id => g_apex_ir_info.region_id); -- set manual for test outside APEX Environment
    g_apex_ir_info.report_definition := APEX_IR.GET_REPORT ( p_page_id => g_apex_ir_info.page_id, p_region_id => g_apex_ir_info.region_id);
    g_apex_ir_info.aggregates_offset := regexp_count(substr(g_apex_ir_info.report_definition.sql_query, 1, INSTR(UPPER(g_apex_ir_info.report_definition.sql_query), ') OVER (')), ',');
    
    -- Generation Options
    g_xlsx_options.show_aggregates := p_aggregates;
    g_xlsx_options.process_highlights := p_process_highlights;
    g_xlsx_options.show_title := p_show_report_title;
    g_xlsx_options.show_filters := p_show_filters;
    g_xlsx_options.show_highlights := p_show_highlights;
    g_xlsx_options.show_column_headers := p_column_headers;
    g_xlsx_options.display_column_count := 0; -- shift result set to right if > 0
    g_xlsx_options.default_font := 'Arial';
    g_xlsx_options.default_border_color := 'b0a070'; -- not yet implemented...
    g_xlsx_options.allow_wrap_text := TRUE;
    g_xlsx_options.original_line_break := p_original_line_break;
    g_xlsx_options.replace_line_break := p_replace_line_break;
    g_xlsx_options.append_date_file_name := p_append_date;
    g_xlsx_options.sheet := xlsx_builder_pkg.new_sheet; -- needed before running any xlsx_builder_pkg commands

    -- retrieve IR infos
    get_settings;
    -- construct full SQL and prepare cursor    
    prepare_cursor;
    
    -- print header if any header option is enabled
    IF g_xlsx_options.show_title OR g_xlsx_options.show_filters OR g_xlsx_options.show_highlights THEN
      print_header;
    END IF;
    
    -- print column headings if enabled
    IF g_xlsx_options.show_column_headers THEN
      print_column_headers;
    END IF;

    -- Generate the "real" data
    print_data;
    
    -- return the generated spreadsheet and file info
    l_retval.file_content := xlsx_builder_pkg.FINISH;
    l_retval.file_name := g_apex_ir_info.report_title || CASE WHEN g_xlsx_options.append_date_file_name THEN '_' || to_char(SYSDATE, 'YYYYMMDD') ELSE NULL END || '.xlsx';
    l_retval.mime_type := 'application/octet';
    l_retval.file_size := dbms_lob.getlength(l_retval.file_content);
    RETURN l_retval;
  EXCEPTION
    WHEN OTHERS THEN
      IF dbms_sql.is_open( g_cursor_info.cursor_id ) THEN
        dbms_sql.close_cursor( g_cursor_info.cursor_id );
      END IF;
      RETURN NULL;
  END apexir2sheet;

END APEXIR_XLSX_PKG;

/