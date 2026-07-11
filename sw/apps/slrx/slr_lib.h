#ifndef _SLR_LIB_H_
#define _SLR_LIB_H_

#include <k5_libs.h>

//----------------------------------------------------------------------------------------------------------


#define NUM_LABELS      27 // Number of output labels
#define IMG_DIM         32 // Input square Image Dimension
#define CONV_KERNEL_DIM  5 // Convolution kernel dimension (for both conv layers)
#define LIN_HID_DIM     32 // hidden linear dimension

//----------------------------------------------------------------------------------------------------------

#define POST_C0_FM_DIM (IMG_DIM-CONV_KERNEL_DIM+1)    // Post Conv0 Feature-Map 
#define POST_P0_FM_DIM (POST_C0_FM_DIM/2)          // Post Pool0 Feature-Map 
     
#define POST_C1_FM_DIM (POST_P0_FM_DIM-CONV_KERNEL_DIM+1)  // Post Conv1 Feature-Map 
#define POST_P1_FM_DIM (POST_C1_FM_DIM/2)           // Post Pool1 Feature-Map 

#define LIN_INVEC_SIZE (POST_P1_FM_DIM*POST_P1_FM_DIM) // Flat post pool0 image

#ifdef _NUM_ITR_
#define NUM_TEST_IMAGES _NUM_ITR_
#else  
#define NUM_TEST_IMAGES 100
#endif

//----------------------------------------------------------------------------------------------------------

typedef struct {  

  // model layers trained loadable parameters matrices
  // DO NOT CHANGE ORDER , matches loaded params file structure !

  //                   num_rows      num_columns

  int8_t    conv0_w    [CONV_KERNEL_DIM]    [CONV_KERNEL_DIM];     // conv0 kernel params
  int32_t   conv0_b;                 
                                     
  int8_t    conv1_w    [CONV_KERNEL_DIM]    [CONV_KERNEL_DIM];     // conv1 kernel params
  int32_t   conv1_b; 

  int8_t    lin0_w_trn [LIN_HID_DIM] [LIN_INVEC_SIZE]; // lin0  projection params, TRANSPOSED!
  int32_t   lin0_b     [LIN_HID_DIM];                  // lin0  bias vector 
 
  int8_t    lin1_w_trn [NUM_LABELS]  [LIN_HID_DIM];    // lin1 projection params, TRANSPOSED!
  int32_t   lin1_b     [NUM_LABELS];                   // lin1 bias vector

} slr_model_params_t ; 

//----------------------------------------------------------------------------------------------------------

typedef struct   { 

  // layers intermediate feature-maps , to be computed along recognition
  // Notice all intermediate feature-maps are positive as they come out of a RELU activation.

  //                  num_rows        num_columns
  uint8_t  post_c0_fm [POST_C0_FM_DIM][POST_C0_FM_DIM]; // Post Conv0
  uint8_t  post_p0_fm [POST_P0_FM_DIM][POST_P0_FM_DIM]; // Post Pool0
  uint8_t  post_c1_fm [POST_C0_FM_DIM][POST_C1_FM_DIM]; // Post Conv1
  uint8_t  post_p1_fm [POST_P0_FM_DIM][POST_P1_FM_DIM]; // Post Pool1

  uint8_t  post_lin0_fm [LIN_HID_DIM]; // Post Lin0
  uint8_t  post_lin1_fm [NUM_LABELS]; // Post Lin1 (also final)

} slr_intr_fm_t ; 

//----------------------------------------------------------------------------------------------------------

typedef struct  {  

  // data set image structure
  // DO NOT CHANGE ORDER , matches loaded file structure !
  // Notice struct size is multiple of 4 bytes assuming IMG_DIM is even (32)
                               
  uint16_t slr_img_idx;        // index of image within dataset 
  uint8_t  is_last_img ;       // Indicate  last image.  
  uint8_t  slr_img_label_id;   // Expected Label ID of image

  uint8_t slr_img [IMG_DIM][IMG_DIM];  // SLR Image pixels array (all positive)

} slr_ds_image_t ; 

//-------------------------------------------------------------------------------------------------------------

slr_model_params_t* load_model_params(); 

void output_detection(int detected_label_id, int expected_label_id, int img_idx, char is_last_ds_img, char text_mode);

//-------------------------------------------------------------------------------------------------------------

#endif