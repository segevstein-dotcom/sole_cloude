
def set_args(args) : 

   args.tdl   = False         # tourchvision downloaded dataset (train and dev)   
   args.spl   = False         # Split train,validate from master dataset  
   args.dbn   = 'slr'         # dataset base name
   args.ver   = ''            # dataset version (within name)    
   args.tp    = '0.1'         # Test set percentage 0 to 1       
   args.nep   = '200'         # Number of epoch  
   args.bs    = '50'          # batch size 
   args.lr    = '0.001'       # Learn rate
   args.ncl   = '2'           # num conv layers
   args.pool  = True          # apply max pooling 2x2 after each conv layer , currently applicable only without padding  
   args.nfl   = '2'           # num FC layers  
   args.fhd   = '32'          # explicit hidden FC dims , args.nfl-1 comma separated integers      
   args.nhcc  = '1'           # num hidden conv out ch     
   args.nlcc  = '1'           # num last conv out ch, default  
   args.ccc   = 'NA'          # explicit ch_out per conv layer config, ex: \'2,4,8\' override nhcc,nlcc        
   args.cgr   = 'NA'          # explicit grouping for ccc option, ex: \'2,4,8\'      
   args.pad   = '0'           # num conv layers padding per edge, or \'mrp\' for minimal required padding, default 0      
   args.cdop  = '0.02'        # dropout percentage  for all conv layers default=0.0         
   args.ldop  = '0.02'        # dropout percentage for all linear (FC) layers default=0.0          
   args.bn    = True          # Apply Batch Normalization          
   args.nds   = '0'           # num depthwise separable stages, default 0, in case non zero override conflicting other arguments    
   args.rds   = False         # Apply residual around depthwise separable stages   
   args.grp   = 1             # num conv2d groups, default          
   args.nrl   = 0             # num rnn layers, default 0   
   args.rhs   = 0             # rnn hidden size  
   args.tcpt  = False         # transform conv out tensor to col per rime, default is row per time   
   args.rbid  = False         # Apply RNN bidirectional option  
   args.nlb   = False         # Do NOT apply FC (Linear) layers Bias')  
   args.ncb   = False         # Do NOT apply Conv2D layers Bias')         
   args.nrb   = True          # Do NOT apply RNN Bias')            
   





