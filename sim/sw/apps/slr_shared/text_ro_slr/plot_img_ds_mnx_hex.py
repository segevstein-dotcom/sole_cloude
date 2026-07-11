import sys
import numpy as np
import matplotlib.pyplot as plt

#-------------------------------------------------------------------------------

def plot_img(img_array, pause_seconds) :
   size_factor = 0.1
   sy = img_array.shape[0]*size_factor
   sx = img_array.shape[1]*size_factor
   plt.figure(figsize=(sy,sx))
   plt.imshow(img_array,cmap='gray',vmin=0,vmax=255,interpolation='quadric')    
   plt.draw()
   plt.pause(pause_seconds)
   plt.clf()

#-------------------------------------------------------------------------------

# main

if __name__ == '__main__':

  # if len(sys.argv)!=2:
  #    print("Missing Argument, Quitting")
  #    exit()
  # 
  # img_hex_dump_file_name = sys.argv[1]
  # imgF = open(img_hex_dump_file_name,'r')  

  ds_imgF = open('outputs/slr_ds_mnx.txt','r')  

  (num_row,num_col) = (32,32)
 
  imgArr = np.zeros(num_row*num_col).reshape(num_row,num_col)
  
  valIdx = 0
  done = False
  rowIdx = 0
  for line in ds_imgF :
    if '#' in line :
      continue
    colIdx = 0  
    for hexValStr in line.split() :  
      imgArr[rowIdx,colIdx] = int(hexValStr,16)
      valIdx = valIdx+1
      colIdx+=1
    rowIdx+=1
    if rowIdx==32:
      break
  imgArr = imgArr[0:rowIdx,0:colIdx]
  plot_img(imgArr,5)  
  ds_imgF.close() 
   