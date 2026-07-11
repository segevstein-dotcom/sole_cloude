import sys
import argparse
import torchvision.datasets as tds
import torchvision.transforms as trans
import torch
import numpy as np
from torch.serialization import safe_globals
from torch.utils.data import TensorDataset

sys.path.append('../../../utils/pymnx/')
import pt_inference as pti

# Loading custom Generated dataset
workspace_path = './workspace/' 

workspace_path = './workspace/'

ap = argparse.ArgumentParser(description='slr Inference',formatter_class=argparse.RawTextHelpFormatter)  
ap.add_argument('-spl'    , metavar='<ds_split>', type=str, default='test', help='dataset split portion, one of: test,val,train,full (default test)')
ap.add_argument('-wfn'   , metavar='<weights_src_name>' , type=str, help='Model weights source file name') 
ap.add_argument('-nt'    , metavar='<num_tests>'        , type=str, default='ALL', help='Number of Tests (default: all available)')
ap.add_argument('-sbn'   , action='store_true'                    , help='Skip Batch-Normalization (override model driven')  
ap.add_argument('-dbg'   , action='store_true'                    , help='Enable some debug prints') 
ap.add_argument('-mnx'   , action='store_true'                    , help='Apply Mannix Descale') 
ap.add_argument('-cusr'  , action='store_true'                    , help='Custom rnn mode')
ap.add_argument('-bnf'   , action='store_true'                    , help='Batch-Normalization Folding , applicable only if -sbn is False')
  
args = ap.parse_args()

test_set_file_name =  workspace_path + ('slr_%s.pt' % args.spl)

print("Loading Test dataset from: %s" % test_set_file_name)
with safe_globals([TensorDataset]):
  test_set= torch.load(test_set_file_name) 
  
if args.nt=='ALL' : 
  num_avail_tests = len(test_set['pt_ds'].tensors[0])
  args.nt = '%s' % num_avail_tests

infer = pti.infer(args)

infer.check_inference_on_test_dataset(args,test_set)  


