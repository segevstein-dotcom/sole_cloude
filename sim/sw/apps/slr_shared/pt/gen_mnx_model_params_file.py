import sys
import argparse
import torch
import numpy as np
import os
import math
sys.path.append('../../../utils/pymnx/')
import pt_nn_model as nnm
import bn_fold as bnf

#--------------------------------------------------------------------------------

class DictObj:
  def __init__(self, in_dict:dict):
        assert isinstance(in_dict, dict)
        for key, val in in_dict.items():
            if isinstance(val, (list, tuple)):
              setattr(self, key, [DictObj(x) if isinstance(x, dict) else x for x in val])
            else:
              setattr(self, key, DictObj(val) if isinstance(val, dict) else val)
             
#--------------------------------------------------------------------------------

def tohex(val, nbits): 
    val = (val + (1 << nbits)) % (1 << nbits)
    if (nbits==8) :
      return '%02x' % val
    elif (nbits==32) :
      return '%08x' % val  
    else :      
      print('ERROR: tohex supports only nbits 8 or 32')  
      exit

#-------------------------------------------------------------------------------------

class Struct: # Used yo convert dictionary to object with attributes
    def __init__(self, **entries):
        self.__dict__.update(entries) 
        
#-------------------------------------------------------------------------------------

def np_save_mnx_params(mnx_params_f, mtrx_id_str, np_arr ,mtrx_type) :
   if mtrx_type=='w' : # weights

       mnx_params_f.write('\n# %s (%d,%d)\n\n' % (mtrx_id_str, np_arr.shape[0],np_arr.shape[1])) 
       for i in range(np_arr.shape[0]) :
           for j in range(np_arr.shape[1]) :          
                val_8b_str = tohex(np_arr[i,j],8)
                mnx_params_f.write('%s' % val_8b_str)
                if (j!=(np_arr.shape[1]-1)) :
                  mnx_params_f.write(' ')
           mnx_params_f.write('\n')
        
       # Alignment padding
       mod4 = (np_arr.shape[0]*np_arr.shape[1]) % 4
       if mod4!=0 :
          num_algnmnt_pad_bytes = 4-mod4
          for i in range(num_algnmnt_pad_bytes) :
            mnx_params_f.write('00')
            if (i!=num_algnmnt_pad_bytes-1) :
             mnx_params_f.write(' ')
            else :
             mnx_params_f.write('\n')

   else : # Bias

     mnx_params_f.write('\n# %s (%d)\n\n' % (mtrx_id_str, np_arr.shape[0]))
     for i in range(np_arr.shape[0]) :
           val_32b_str = tohex(np_arr[i],32)
           mnx_params_f.write('%s %s %s %s \n' % 
           (val_32b_str[6:8],val_32b_str[4:6],val_32b_str[2:4],val_32b_str[0:2]))
       
#----------------------------------------------------------------------------------

def save_out(mtrx_id_str,np_arr,mtrx_type, mnx_params_f, args, scale_params) :
  global model_total_num_param_bytes # Ugly global param
  global ih_matrix 
  
  print('Processing matrix %s ; shape = (%s)' %(mtrx_id_str,str(np_arr.shape)))
  
  if args.csv :    
     np.savetxt("csv_dumps/float_orig/%s.csv" % mtrx_id_str , np_arr, fmt='%f', delimiter=",")
              
  (conv_w_scale_list, conv_b_scale_list, rnn_i_scale_list, rnn_h_scale_list, fc_w_scale_list, fc_b_scale_list) = scale_params
  
  if  'conv' in mtrx_id_str :
     cl = int(mtrx_id_str[4:mtrx_id_str.find('_')])
     w_scale = conv_w_scale_list[cl]
     b_scale = conv_b_scale_list[cl] 
     
  elif  'rnn.weight_ih' in mtrx_id_str :
     print(mtrx_id_str)     
     rl = int(mtrx_id_str[mtrx_id_str.find('l')+1:mtrx_id_str.find('_w')])
     w_scale = rnn_i_scale_list[rl]
     
  elif  'rnn.weight_hh' in mtrx_id_str :
     print(mtrx_id_str)
     rl = int(mtrx_id_str[mtrx_id_str.find('l')+1:mtrx_id_str.find('_w')])
     w_scale = rnn_h_scale_list[rl]
  
  elif  'fc' in mtrx_id_str :
     fl = int(mtrx_id_str[2:mtrx_id_str.find('_')])
     w_scale = fc_w_scale_list[fl]
     b_scale = fc_b_scale_list[fl] 
          
  scale_val = w_scale if mtrx_type=='w' else b_scale
  
  max_clamp_val,min_clamp_val = (127,-128) if mtrx_type=='w' else ((2**31)-1,-1*(2**31))

  np_arr_sc_int = (scale_val * np_arr).astype(int)
  np_arr_sc_int_clamp = np.maximum(min_clamp_val,np.minimum(max_clamp_val,np_arr_sc_int))
    
  if args.csv :     
     np.savetxt("csv_dumps/scaled_int/%s.csv" % mtrx_id_str , np_arr_sc_int_clamp , fmt='%i' , delimiter=",")
  
  num_param_bytes = np.prod(np_arr_sc_int_clamp.shape)
  if mtrx_type=='b' :
    num_param_bytes *= 4
  # Alignment padding
  mod4 = num_param_bytes % 4
  if mod4!=0 :
     num_param_bytes += (4-mod4)
    
  model_total_num_param_bytes += num_param_bytes
  print ('Generating %d param bytes of %s'%(num_param_bytes,mtrx_id_str))
  if "ih_" in mtrx_id_str:
      ih_matrix = np_arr_sc_int_clamp
  else:
      if "_hh" in mtrx_id_str :
          mtrx_id_str = mtrx_id_str.replace("_hh","")
          np_arr_sc_int_clamp = np.hstack((ih_matrix, np_arr_sc_int_clamp))
      np_save_mnx_params(mnx_params_f, mtrx_id_str, np_arr_sc_int_clamp, mtrx_type)

#--------------------------------------------------------------------------------

def dump_np_multi2D(np_arr, mtrx_id_str, mtrx_type, mnx_params_f,args, scale_params) :
  #Recursive functions to dump a numpy array with dimensions higher than 2 down to multiple 2D arrays
  
  if (len(np_arr.shape)<=2) :
    save_out(mtrx_id_str, np_arr,mtrx_type, mnx_params_f,args, scale_params)
  else : 
    for i in range(np_arr.shape[0]) :
        dump_np_multi2D(np_arr[i],"%s_%d"%(mtrx_id_str,i),mtrx_type, mnx_params_f,args, scale_params)
  
#--------------------------------------------------------------------------------

def zero_to_pos_inf_abs(x) : # in order to exclude very small numbers from min val finding
   return 9999 if abs(x)<0.00001 else abs(x)

def zero_to_neg_inf_abs(x) : # in order to exclude very small numbers from max val finding
   return -9999 if abs(x)<0.00001 else abs(x)

#--------------------------------------------------------------------------------

def min_max_non_zero_abs(np_arr) :

  vzpa_func = np.vectorize(zero_to_pos_inf_abs, otypes=[np.float64])
  vzna_func = np.vectorize(zero_to_neg_inf_abs, otypes=[np.float64])
  
  abs_min_vec = vzpa_func(np_arr)
  abs_max_vec = vzna_func(np_arr)
 
  min_val = np.amin(abs_min_vec)
  max_val = np.amax(abs_max_vec) 
   
  return (min_val,max_val)

#--------------------------------------------------------------------------------


def calc_scale_params(param_tensors,args,ncl,nfl,nrl,train_args) :

    (conv2d_w_list, conv2d_b_list, rnn_i_w_list, rnn_h_w_list, fc_w_list, fc_b_list) = param_tensors

    rnn_i_min_list , rnn_i_max_list  = [None]*nrl , [None]*nrl
    rnn_h_min_list , rnn_h_max_list  = [None]*nrl , [None]*nrl

    conv_w_min_list , conv_w_max_list  = [None]*ncl , [None]*ncl
    conv_b_min_list , conv_b_max_list  = [None]*ncl , [None]*ncl
            
    for cl in range(ncl) : 
        conv_w_min_list[cl] , conv_w_max_list[cl]  = min_max_non_zero_abs(conv2d_w_list[cl])    
        if not train_args.ncb :         
          conv_b_min_list[cl] , conv_b_max_list[cl]  = min_max_non_zero_abs(conv2d_b_list[cl])
    
    for rl in range(nrl) : 
        rnn_i_min_list[rl] , rnn_i_max_list[rl]  = min_max_non_zero_abs(rnn_i_w_list[rl])      
        rnn_h_min_list[rl] , rnn_h_max_list[rl]  = min_max_non_zero_abs(rnn_h_w_list[rl])

    fc_w_min_list , fc_w_max_list  = [None]*nfl , [None]*nfl
    fc_b_min_list , fc_b_max_list  = [None]*nfl , [None]*nfl


    for fl in range(nfl) : 
        fc_w_min_list[fl] , fc_w_max_list[fl] = min_max_non_zero_abs(fc_w_list[fl])
        if not train_args.nlb :         
           fc_b_min_list[fl] , fc_b_max_list[fl] = min_max_non_zero_abs(fc_b_list[fl])
    
    # Notice Mannix is hardwired to descale output by 256
    # NOTICE , for CONV layers beyond 1  though bias is per cube filter, HW multiply it by depth (due to old bug in original generation)  

    sapl_val = float(args.sapl)
    
    # CONV
    
    conv_w_scale_list     =  [None]*ncl
    conv_b_scale_list     =  [None]*ncl
    conv_inout_scale_list =  [None]*ncl
    
    for cl in range(ncl) : 
        prev_layer_scale = 1 if (cl==0) else conv_inout_scale_list[cl-1]
        cl_depth = conv2d_w_list[cl].shape[1]
        print('Indicated  conv%d depth (num input channels) : %d' %(cl,cl_depth))
        cl_b_div_fix = cl_depth # HW bug workaround required, (HW multiply it by depth) 

        conv_scale = 128/conv_w_max_list[cl]
        conv_w_scale_list[cl]     = np.rint(conv_scale*sapl_val)
        conv_b_scale_list[cl]     = np.rint((conv_scale*prev_layer_scale*sapl_val)/cl_b_div_fix)        
        conv_inout_scale_list[cl] = prev_layer_scale*conv_w_scale_list[cl]/256 # Division by 256 due to HW descaling , TODO Check if correct and same for all layers

    # RNN
  
    rnn_i_scale_list     =  [None]*nrl
    rnn_h_scale_list     =  [None]*nrl

    for rl in range(nrl) : 
    
        if args.srf==None :
           rnn_i_scale = 128/rnn_i_max_list[rl]
           rnn_h_scale = 128/rnn_h_max_list[rl]
           rnn_i_scale_list[rl]     = np.rint(rnn_i_scale*sapl_val)
           rnn_h_scale_list[rl]     = np.rint(rnn_h_scale*sapl_val)
        else :
           rnn_i_scale_list[rl]     = int(args.srf)
           rnn_h_scale_list[rl]     = int(args.srf)
       
    # FC
       
    fc_w_scale_list     =  [None]*nfl
    fc_b_scale_list     =  [None]*nfl
    fc_inout_scale_list =  [None]*nfl
    
    for fl in range(nfl) : 
        first_fc_layer_scale = 1 if (ncl==0) else conv_inout_scale_list[-1]
        prev_layer_scale = first_fc_layer_scale if (fl==0) else fc_inout_scale_list[fl-1]

        fc_scale = 128/fc_w_max_list[fl]
        fc_w_scale_list[fl]     = np.rint(fc_scale*sapl_val)
        fc_b_scale_list[fl]     = np.rint((fc_scale*prev_layer_scale*sapl_val))        
        fc_inout_scale_list[fl] = prev_layer_scale*fc_w_scale_list[fl]/256 # Division by 256 due to HW descaling , TODO Check if correct and same for all layers
    
    scale_params = (conv_w_scale_list, conv_b_scale_list, rnn_i_scale_list, rnn_h_scale_list, fc_w_scale_list, fc_b_scale_list) 
       
    do_print_wb_scale = True         
    if do_print_wb_scale :
     
         print('')         
         for cl in range(ncl):
           if not train_args.ncb :         
             print('CONV%d abs ranges pre scale: w:(%f,%f), b:(%f,%f)' % 
             (cl,conv_w_min_list[cl], conv_w_max_list[cl], conv_b_min_list[cl], conv_b_max_list[cl]))
           else:
             print('CONV%d abs ranges pre scale: w:(%f,%f)' % (cl,conv_w_min_list[cl], conv_w_max_list[cl], ))           
         print('')          
         print('')
         
         for rl in range(nrl):    
           print('RNN%d abs ranges pre scale: convert_mat:(%f,%f), hidden_mat:(%f,%f)' % 
           (rl,rnn_i_min_list[rl], rnn_i_max_list[rl], rnn_h_min_list[rl], rnn_h_max_list[rl]))
         print('') 
         
         for fl in range(nfl):    
           if not train_args.nlb : 
               print('FC%d abs ranges pre scale: w:(%f,%f), b:(%f,%f)' % 
               (fl,fc_w_min_list[fl], fc_w_max_list[fl], fc_b_min_list[fl], fc_b_max_list[fl]))
           else:
               print('FC%d abs ranges pre scale: w:(%f,%f)' % (fl,fc_w_min_list[fl], fc_w_max_list[fl]))           
         print('')         

         for cl in range(ncl):
           if not train_args.ncb :
              print ('conv%d_w_scale=%d, conv%d_b_scale=%d'  % (cl, conv_w_scale_list[cl], cl, conv_b_scale_list[cl]))
           else:
              print ('conv%d_w_scale=%d'  % (cl, conv_w_scale_list[cl]))           

         for rl in range(nrl):
           print ('RNN%d_ih_scale=%d, RNN%d_hh_scale=%d'  % (rl, rnn_i_scale_list[rl], rl, rnn_h_scale_list[rl]))

         for fl in range(nfl):
           print ('fc%d_w_scale=%d, fc%d_b_scale=%d'  % (fl, fc_w_scale_list[fl], fl, fc_b_scale_list[fl]))

         print('')
    
    return scale_params 

#---------------------------------------------------------------------------------------------------------------------------

def run_gen(args) : 
     
     wfn_prfx = args.wfn[:args.wfn.find('.')]
     mnx_params_f = open('%s_mnx_params.txt'%(wfn_prfx),'w')
     device = None            # Not Applicable       

     print("Loading model params from: %s" % args.wfn)
     loaded_dict = torch.load(args.wfn, map_location=device, weights_only=False)

     weights      = loaded_dict['model_state']
     fc_dim       = loaded_dict['fc_dim'] 
     num_conv_ch  = loaded_dict['num_conv_ch']
     pad          = loaded_dict['pad']
     ncl          = loaded_dict['ncl'] 
     ris          = loaded_dict['ris']      
     train_args   = DictObj(loaded_dict['train_args']) 
     nrl       = train_args.nrl            
     rhs       = train_args.rhs
     apply_bn  = train_args.bn             
     nfl       = int(train_args.nfl)       
     cdop      = float(train_args.cdop)    
     ldop      = float(train_args.ldop)        
     
     model = nnm.nn_model(args=train_args,num_conv_ch=num_conv_ch,fc_dim=fc_dim,device=device,apply_bn=apply_bn, 
                          ncl=ncl, pool=train_args.pool, nfl=nfl, pad=pad,
                          cdop=cdop, ldop=ldop, ris=ris, mnx=True,cusr=False,dbg=False).to(device)        

     model.load_state_dict(weights) # Loading a model , just helps to extract params, not really executed here
 
     if apply_bn :
       # Detected model includes batch normalization, performing bn folding
       model = bnf.bn_fold(model)
       weights = model.state_dict()
 
     # putting all params in lists of numpy arrays
 
     fc_w_list = []
     fc_b_list = []
 
     for fl in range(nfl) :                                        
        fc_attr = getattr(model.layers,'fc%d'%fl)
        fc_w_list.append(fc_attr.weight.data.detach().numpy())
        if not (train_args.nlb) : 
           fc_b_list.append(fc_attr.bias.data.detach().numpy())
        else : # provide zero bias
           num_bias_elmnts = fc_w_list[-1].shape[0]
           fc_b_list.append(np.zeros(num_bias_elmnts))
         
     conv2d_w_list = []
     conv2d_b_list = []
     
     for cl in range(ncl) : 
        conv_attr = getattr(model.layers,'conv2d_%d'%cl)
        conv2d_w_list.append(conv_attr.weight.data.detach().numpy())
        if not (train_args.ncb) :         
           conv2d_b_list.append(conv_attr.bias.data.detach().numpy())
        else : # provide zero bias
           num_bias_elmnts = conv2d_w_list[-1].shape[0] # TODO Check correct shape index 
           conv2d_b_list.append(np.zeros(num_bias_elmnts))
           
     rnn_i_w_list = []
     rnn_h_w_list = []

     for rnni in range(nrl):
        rnn_attr = getattr(model.layers, 'rnn')

        # Access input-hidden weights and biases
        for layer_idx in range(nrl): 
            ih_weight_attr = f'weight_ih_l{layer_idx}'
            hh_weight_attr = f'weight_hh_l{layer_idx}'

            rnn_i_w_list.append(getattr(rnn_attr, ih_weight_attr).data.detach().numpy())
            rnn_h_w_list.append(getattr(rnn_attr, hh_weight_attr).data.detach().numpy())
     
     param_tensors = (conv2d_w_list, conv2d_b_list, rnn_i_w_list, rnn_h_w_list, fc_w_list, fc_b_list) 
                             
     scale_params = calc_scale_params(param_tensors,args,ncl,nfl,nrl,train_args) # Calculating the desired scaling per layer.
                    
     if args.csv :                                # csv option for user friendly params access                
        if not os.path.exists('csv_dumps'):
            os.makedirs('csv_dumps')
        if not os.path.exists('csv_dumps/float_orig'):
            os.makedirs('csv_dumps/float_orig')
            
        if not os.path.exists('csv_dumps/scaled_int'):
            os.makedirs('csv_dumps/scaled_int')

     # quantize and dump params 

     for cl in range(ncl) : 
        dump_np_multi2D(conv2d_w_list[cl],'conv%d_w'%cl,'w', mnx_params_f,args, scale_params)
        dump_np_multi2D(conv2d_b_list[cl],'conv%d_b'%cl,'b', mnx_params_f,args, scale_params)

     for rl in range(nrl) : 
        save_out('rnn.weight_ih_l%d_w'%rl, rnn_i_w_list[rl],'w', mnx_params_f,args, scale_params)
        save_out('rnn.weight_hh_l%d_w'%rl, rnn_h_w_list[rl],'w', mnx_params_f,args, scale_params)
        
     for fl in range(nfl) : 
        save_out('fc%d_w'%fl , fc_w_list[fl],'w', mnx_params_f,args, scale_params)
        save_out('fc%d_b'%fl , fc_b_list[fl],'b', mnx_params_f,args, scale_params)
         
     mnx_params_f.close()

     wfn_prfx = args.wfn[:args.wfn.find('.')]   

     # Copy to leo app area without comments
     # os.system("grep -v '\\#'  runspace/mnx_params.txt > ../model_params_db/model_params_mfdb.txt")
     sys_cmd = "grep -v '\\#'  %s_mnx_params.txt > %s_model_params_mfdb.txt" % (wfn_prfx,wfn_prfx)
     os.system(sys_cmd)
     print(sys_cmd)
     # Write Configuration file
     mnx_cnf_f = open('%s_mannix_model_config.txt'%wfn_prfx,'w')

     mnx_cnf_f.write('num_conv_layers  %3d\n' % ncl)
     mnx_cnf_f.write('pool             %3d\n' % (1 if train_args.pool else 0)) 
     mnx_cnf_f.write('num_rnn_layers   %3d\n' % nrl) 
     mnx_cnf_f.write('rnn_input_size   %3d\n' % ris)        
     mnx_cnf_f.write('rnn_hidden_size  %3d\n' % rhs)      
     mnx_cnf_f.write('num_fc_layers    %3d\n' % nfl)     
     mnx_cnf_f.write('img_num_row      %3d\n' % train_args.img_num_row)
     mnx_cnf_f.write('img_num_col      %3d\n' % train_args.img_num_col)
     
     mnx_cnf_f.write('no_conv_bias     %3d\n' % train_args.ncb)
     mnx_cnf_f.write('no_fc_bias       %3d\n' % train_args.nlb)     

     if (ncl>0) :
       mnx_cnf_f.write('num_conv_ch          ')
       for num_ch in num_conv_ch :            
         mnx_cnf_f.write('%3d ' % num_ch)  
       mnx_cnf_f.write('\n')        

     mnx_cnf_f.write('fc_dim               ')
     for dim in fc_dim :            
       mnx_cnf_f.write('%3d ' % dim)  
     mnx_cnf_f.write('\n')        

     mnx_cnf_f.close()
     
  
     # Write labels h file.
    
     labels_hf = open('%s_labels.h'%wfn_prfx,'w')
      
     labels_hf.write('const char* class_str[] = {\n')
    
     lnbi = loaded_dict['lnbi'] 
    
     for i in range(len(lnbi)) :
       if i!=(len(lnbi)-1) :  # not last label
         labels_hf.write('\"%s\", // %d\n' % (lnbi[i],i))
       else :
         labels_hf.write('\"%s\" //  %d\n};\n' % (lnbi[i],i))
     labels_hf.close()
    
    
    #-----------------------------------------------------------------------------------------------------------
          
     if args.qpt :
     
        def update_layer_weights(layer_name, scale_w, scale_b, weights, is_conv,cl) :
        
            is_rnn = layer_name.find('rnn')>=0 
            wstr = '' if is_rnn else '.weight'

        
            # Weights        
            w_np = (weights['layers.'+layer_name+wstr]).detach().numpy()
            w_max_clamp_val,w_min_clamp_val = (127,-128) 
            np_arr_sc_int = (scale_w * w_np).astype(int)
            w_np_arr_sc_int_clamp = np.maximum(w_min_clamp_val,np.minimum(w_max_clamp_val,np_arr_sc_int))      
            weights['layers.'+layer_name+wstr] = torch.from_numpy(w_np_arr_sc_int_clamp)

            #Bias
            if (scale_b != None) and not train_args.nlb :             
             
              b_np = (weights['layers.'+layer_name+'.bias']).detach().numpy()
              b_max_clamp_val,b_min_clamp_val = ((2**31)-1,-1*(2**31))  

              b_np_arr_sc_int = (scale_b * b_np).astype(int)                     
              b_np_arr_sc_int_clamp = np.maximum(b_min_clamp_val,np.minimum(b_max_clamp_val,b_np_arr_sc_int))
               
            if (is_conv): 
            
              cl_depth = w_np.shape[1] 
              print('QPT: Indicated conv%d depth (num input channels) : %d' %(cl,cl_depth))
              if not train_args.nlb : 
                 b_np_arr_sc_int_clamp *= cl_depth # For compatibility as mannix due to HW multiply it by depth                
            
            if (scale_b != None) and not train_args.nlb :              
               weights['layers.'+layer_name+'.bias'] = torch.from_numpy(b_np_arr_sc_int_clamp)

              
        #-----------------------------------------------------------------------------

        (conv_w_scale_list, conv_b_scale_list, rnn_i_scale_list, rnn_h_scale_list, fc_w_scale_list, fc_b_scale_list) = scale_params
          
        for cl in range(ncl) :
            update_layer_weights('conv2d_%d'%cl, conv_w_scale_list[cl], conv_b_scale_list[cl], weights, is_conv=True,cl=cl)

        for fl in range(nfl) :
            update_layer_weights('fc%d'%fl, fc_w_scale_list[fl], fc_b_scale_list[fl], weights, is_conv=False,cl=None)


        for rl in range(nrl) :
            update_layer_weights('rnn.weight_ih_l%d'%rl, rnn_i_scale_list[rl], None, weights, is_conv=False,cl=None)   # TMP RNN Bias not supported
            update_layer_weights('rnn.weight_hh_l%d'%rl, rnn_h_scale_list[rl], None, weights, is_conv=False,cl=None)   # TMP RNN Bias not supported

        wfn_prfx = args.wfn[:args.wfn.find('.')] 
        torch.save(weights ,'%s_mnx_params.pt'%wfn_prfx) # TODO change to meaningful name  out file
    
     #-----------------------------------------------------------------------------
     
     if apply_bn :
       print('\nNotice: Detected model includes batch normalization, performing bn folding')
    
#----------------------------------------------------------------------------------------------------------------

if __name__ == '__main__':

    ap = argparse.ArgumentParser(description='Generate Mannix model params fle',formatter_class=argparse.RawTextHelpFormatter)    
    ap.add_argument('-wfn'  , metavar='<weights_src_name>' , type=str,                help='Model weights source file name') 
    ap.add_argument('-sapl' , metavar='<auto_scale>'       , type=str, default='1',   help='Auto scale per layer , followed by factor for all layers (default 1)')
    ap.add_argument('-srf'  , metavar='<scale_rnn_fixed>'  , type=str, default=None,   help='scale rnn layers params by fixed factor (default None, apply auto)')
    ap.add_argument('-csv'  , action='store_true'          ,                          help='Generate csv dumps (for debug purposes)')          
    ap.add_argument('-qpt'  , action='store_true'          ,                          help='Generate a pyTorch quantize model (mostly for cross verification)')    
    args = ap.parse_args()
    model_total_num_param_bytes = 0 # Ugly global param
    run_gen(args)  
    print('\nNOTICE: Model parameters total byte count is %d\nMake sure it fits into implementation limit' % model_total_num_param_bytes)    
