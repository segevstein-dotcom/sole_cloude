from itertools import product
import torch
import argparse
import numpy as np
import sys
import os
import math
from pathlib import Path
import torchvision.datasets as tds
import torchvision.transforms as trans
from torch.serialization import safe_globals
from torch.utils.data import TensorDataset
#-------------------------------------------------------------------------------

ap = argparse.ArgumentParser(description='Convert dataset to LEO Mannix text source',formatter_class=argparse.RawTextHelpFormatter)
ap.add_argument('-ddn'  , metavar='<downloaded_dataset_name>' , type=str, default=None,  help='downloaded dataset name (e.g. FashionMNIST)')
ap.add_argument('-wsp'  , metavar='<ws_path>', type=str, default='./workspace', help='eorkspace path (default: ./workspace)')
ap.add_argument('-spl'  , metavar='<ds_split>', type=str, default='test', help='dataset split portion, one of: test,val,train,full,text (default test)')
ap.add_argument('-gdn'  , metavar='<generated_dataset_name>'  , type=str, default=None,  help='generated dataset name (e.g. mnist)')
ap.add_argument('-ni'   , metavar='<num_imgs>'                , type=str, default='all', help='Number of images convert (default all)')   
  
args = ap.parse_args()

#----------------------------------------------------------------------------------------------------------------

image_transform = trans.Compose([
  trans.Lambda(lambda image: torch.from_numpy(np.array(image).astype(np.float32)).unsqueeze(0))
])

if args.ddn : # Downloaded
   ds_access = getattr(tds,args.ddn)
   split_set = ds_access(root='./dataset/',train=False,download=True, transform=image_transform)
elif args.gdn : # Generated
# Loading custom Generated dataset
   workspace_path = args.wsp + '/'
   split_set_file_name =  workspace_path + args.gdn + ('_ds_%s.pt' % args.spl)  
   
   if not Path(split_set_file_name).is_file():
     print('Cant find split_set_file_name %s' % split_set_file_name)
     split_set_file_name =  workspace_path + args.gdn + ('_%s.pt' % args.spl)
     print('Trying also to find split_set_file_name %s' % split_set_file_name)
     if not Path(split_set_file_name).is_file():
       print('Cant find split_set_file_name %s' % split_set_file_name)
       split_set_file_name =  workspace_path + args.gdn + '_ds.pt'
       print('Trying also to find split_set_file_name %s' % split_set_file_name)
       if not Path(split_set_file_name).is_file():
         print('Cant find split_set_file_name %s' % split_set_file_name)
         exit()
  
   print("Loading dataset from: %s" % split_set_file_name)
   
   with safe_globals([TensorDataset]):
     
     dataset_loaded_dict = torch.load(split_set_file_name)
     split_set = dataset_loaded_dict['pt_ds']     
     lnbi      = dataset_loaded_dict['lnbi']    
     imgp      = dataset_loaded_dict['imgp'] 
    
else: 
   print('ERROR: Must provide attribute -ddn or -gdn')
   exit()
   
#----------------------------------------------------------------------------------------------------------------

if args.ddn  : # Downloaded
  np_dataset = split_set.data.numpy().astype(int)
  np_targets = split_set.targets.numpy().astype(int)

elif args.gdn : # Generated
  np_dataset = (split_set.tensors[0]).numpy().astype(int)
  np_targets = (split_set.tensors[1]).numpy().astype(int)
 
else: 
   print('ERROR: Must provide attribute -ddn or -gdn')
   exit()

ds_size = np_dataset.shape[0]

print('Size of Test data set:  %d' % ds_size)

#-----------------------------------------------------------------------------------------------------------------

img_num_row = np_dataset.shape[1] 
img_num_col  = np_dataset.shape[2] 

print('Detected image dimensions: %dX%d' % (img_num_row,img_num_col))

dsn = args.ddn if args.ddn else args.gdn
mnx_ds_txt_file_name =  args.wsp + '/' + dsn + '_ds_mnx.txt'

mnx_ds_txt_file = open(mnx_ds_txt_file_name,'w')

#-----------------------------------------------------------------------------------------------------------------

img_idx = 0
for img_idx in range(ds_size) :

    img = np_dataset[img_idx] 
    label = np_targets[img_idx] 

    if (img_idx < len(imgp)) : 
      mnx_ds_txt_file.write('# %s\n' % imgp[img_idx])
    else:
      mnx_ds_txt_file.write('# pseudo space\n')

    # Indicate last image
    is_last_img = img_idx==(ds_size-1)
    last_img_flag = 1 if is_last_img else 0   
    last_img_str = ' , LAST IMAGE' if is_last_img else ''  
    
    #  write index as little endian short (2 bytes) , indicate last image
    mnx_ds_txt_file.write('%02x %02x %02x ' % (int(img_idx)%256, (int(img_idx)//256)%256, last_img_flag))  
    mnx_ds_txt_file.write('# image running idx: %d %s\n' % (img_idx, last_img_str))      
    mnx_ds_txt_file.write('%02x # label index: %d (\'%s\')\n\n' % (label,label,lnbi[label]))  #  write label as little endian short (2 bytes)

    img = np.maximum(0,np.minimum(255,img))  # Assume all values are in range of 0 to 255     
    for r in range(img.shape[0]) : 
      for c in range(img.shape[1]) :        
          mnx_ds_txt_file.write(' %02x' % int(img[r][c]))                        
      mnx_ds_txt_file.write('\n')
      
    mnx_ds_txt_file.write('\n')
    
    # assuming all spaces are at end of data set, testing only one image (ass all are same zero arrays)
    if img_idx==len(imgp) :
      break       
    
    img_idx += 1
    if args.ni!='all' :
       if img_idx==int(args.ni) :
         break
  
mnx_ds_txt_file.close()

#----------------------------------------------------------------------------------------------------------------


