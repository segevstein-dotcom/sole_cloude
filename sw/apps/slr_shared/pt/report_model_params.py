import torch
import sys
import argparse
import torch
import thop # Provided by pip install --upgrade git+https://github.com/Lyken17/pytorch-OpCounter.git
sys.path.append('../../../utils/pymnx/')
import pt_nn_model as nnm
#--------------------------------------------------------------------------------

class DictObj:
  def __init__(self, in_dict:dict):
        assert isinstance(in_dict, dict)
        for key, val in in_dict.items():
            if isinstance(val, (list, tuple)):
              setattr(self, key, [DictObj(x) if isinstance(x, dict) else x for x in val])
            else:
              setattr(self, key, DictObj(val) if isinstance(val, dict) else val)
               
#-------------------------------------------------------------------------------


ap = argparse.ArgumentParser(description='PT Inference',formatter_class=argparse.RawTextHelpFormatter)  
ap.add_argument('-wfn'   , metavar='<weights_src_name>' , type=str, help='Model weights source file name') 
args = ap.parse_args()

print('\nBy Params file parse\n')

spt = torch.load(args.wfn, map_location=torch.device('cpu') ,weights_only=False)
total_num_params = 0
print('\nParameters Count by params file parse\n')
for layer_name  in spt['model_state'] :
  tensor =  spt['model_state'][layer_name]
  tensor_dims = spt['model_state'][layer_name].size()
  tensor_num_params = 1
  for d in range(len(tensor_dims)) :
     tensor_num_params *= tensor_dims[d]  
  print('%-30s %10d' % (layer_name,tensor_num_params))
  total_num_params += tensor_num_params
print('%-30s %10d' % ('Total parameters count',total_num_params))


print('\nBy thop util:\n')

device = torch.device("cpu")  

print("Loading model params from: %s" % args.wfn)
loaded_dict = torch.load(args.wfn, map_location=device, weights_only=False)

train_args   = DictObj(loaded_dict['train_args'])        
num_conv_ch  = loaded_dict['num_conv_ch']
fc_dim       = loaded_dict['fc_dim']    
apply_bn     = loaded_dict['apply_bn']   
ncl          = loaded_dict['ncl'] 
pool         = loaded_dict['pool']       
nfl          = loaded_dict['nfl']        
pad          = loaded_dict['pad']        
cdop         = loaded_dict['cdop']       
ldop         = loaded_dict['ldop']       
ris          = loaded_dict['ris']        
lnbi         = loaded_dict['lnbi']  


 
label_names_by_idx = lnbi        
        
apply_bn = False
   
model = nnm.nn_model(args=train_args,num_conv_ch=num_conv_ch,fc_dim=fc_dim,device=device,apply_bn=apply_bn, 
                    ncl=ncl, pool=pool, nfl=nfl, pad=pad, cdop=cdop, ldop=ldop, ris=ris, mnx=False,dbg=False).to(device) 

print ('Detected trained img_num_col = %d, img_num_row=%d' % (train_args.img_num_col,train_args.img_num_row)) 

nicc = int(train_args.nicc) if hasattr(train_args,'nicc') else 1 # backwards compatible for conf files prior to 'nicc' support
input = torch.randn(1, nicc, train_args.img_num_row, train_args.img_num_col)

# macs, params = profile(model, inputs=(input, )) 
macs, params = thop.profile(model, inputs=(input,)) 
print('\nMAC_COUNT = %d, PARAMS_COUNT = %d\n' %(macs,params))

