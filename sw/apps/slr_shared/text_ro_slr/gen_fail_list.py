fail_ids   = []
fail_paths = []

# Example line:  12: detected: i ; expected: y FAIL
with open('slr_ds_fail_list.txt', 'r') as fail_list_f :
    for line in fail_list_f:
       tokens = line.split()
       if 'FAIL' in tokens :
          fail_ids.append(int(tokens[0][:-1]))

# Example lines:
# # data/g/hand5_g_bot_seg_1_cropped.jpeg 
# 07 07 # image running idx: 1799

with open('../pt/workspace/slr_ds_mnx.txt', 'r') as ds_mnx_f :
    for line in ds_mnx_f:
       if 'jpeg' in line :    
          tokens = line.split()
          path = tokens[1]
       if 'running idx' in line :    
          tokens = line.split()
          idx = int(tokens[-1])
          if idx in fail_ids :
             fail_paths.append(path)

ds_fail_paths_f = open('../pt/workspace/ds_fail_paths.txt', 'w')      
for p in fail_paths :
   ds_fail_paths_f.write('%s\n' % p)
   
ds_fail_paths_f.close()   
   