#!/bin/bash
export LIBS_PATH=$K5_LIBS
shopt -s expand_aliases
source $K5_XBOX_ENV/setup/k5_rc3_setup.sh
export K5_APP_SHARED_LIB="$LIBS_PATH/null_shared_lib"
cd $K5_SW_APPS/sole_ref 
rm -f build/* 
$K5_ENV/sw/sw_utils/comp_app_local_rc3.sh sole_ref _SPMT_  "-D_XBOX_ -I$K5_XBOX_ENV/sw/xbox_libs" _MAX10_FPGA_ 24576
cd -
