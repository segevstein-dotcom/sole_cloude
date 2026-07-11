#include <k5_libs.h>
#include <slr_lib.h>

//-------------------------------------------------------------------------------------------------------------

slr_model_params_t* load_model_params() {
    
    slr_model_params_t* slr_model_params_p ; // Pointer to loaded model parameters structure
 
    int params_total_num_bytes = sizeof(slr_model_params_t) ; // Total number of paameters
   
    slr_model_params_p = (slr_model_params_t*)alloc_get(params_total_num_bytes, "model_params"); 
      
    FILE_REF file_ref ; // assigned by load_hex_file( ... OPEN*)
    //char * params_file_path = "app_src_dir/../slr_shared/pt/workspace/slr_tmw_mnx_params.txt" ;
    char * params_file_path = "$K5_SHARE/slrx_ref/sw/apps/slr_shared/pt/workspace/slr_tmw_mnx_params.txt" ;
  
    printf("Loading %d model parameters from %s\n", params_total_num_bytes, params_file_path);
    load_hex_file(params_file_path, &file_ref, (char *)(slr_model_params_p), params_total_num_bytes, OPEN_LOAD_CLOSE); 
        
    return slr_model_params_p;    
}

//-----------------------------------------------------------------------------------------------------------

    void output_detection( 
        int   detected_label_id,
        int   expected_label_id,
        int   img_idx,
        char  is_last_ds_img,
        char  text_mode
        ) {

        static int fail_cnt = 0;
          
        char detected_char = (detected_label_id==('z'-'a'+1)) ? ' ' : detected_label_id + 'a' ;   
                                   
        if (text_mode) {
          if (img_idx==0) printf("\n\nDETECTED TEXT: \"");   
          printf("%c",detected_char);
          if (is_last_ds_img) printf("\"\n\n");         
           
        } else { 
           char expected_char = (expected_label_id==('z'-'a'+1)) ? ' ' : expected_label_id + 'a' ;             
           char pass = (detected_label_id==expected_label_id);
           if (pass) {
             printf("%3d: detected: %c\n", img_idx, detected_char);
           } else {
             fail_cnt++;
             printf("%3d: detected: '%c' ; expected: '%c' FAIL\n", img_idx, detected_char, expected_char);        
           }
           
           if (is_last_ds_img) {    
                int num_passed = img_idx+1 - fail_cnt;
                float success_prcnt = 100*((float)num_passed)/(float)NUM_TEST_IMAGES ;                
                printf("\nTested %d images,  Passed: %d, Fail: %d, Success: %2.1f%%\n\n",
                       img_idx+1, num_passed, success_prcnt);
           }
        }

    }




//-----------------------------------------------------------------------------------------------------------
