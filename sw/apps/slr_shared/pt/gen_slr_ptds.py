import os
import numpy as np
import argparse
import torch
from PIL import Image
from torch.utils.data import TensorDataset
from torchvision import transforms
import io
import zipfile

#------------------------------------------------------------------------

def process_images(labels_dict, ds_arc, img_size):
    """ Process images and labels from the given directory. """
    img_paths = []
    labels = []

    arc_dirs = list(set([os.path.dirname(x) for x in ds_arc.namelist()]))
        
    for fname in ds_arc.namelist():
         
        if 'jpeg' in fname :
          img_path   = fname[:fname.rfind('/')]
          label_name = fname[fname.find('/')+1:fname.rfind('/')]

          
          if label_name in labels_dict :
            label_idx  = labels_dict[label_name]          
            img_paths.append(fname)          
            labels.append(label_idx)

    return img_paths, labels

#------------------------------------------------------------------------

def split_data(img_paths, labels, train_split, val_split, test_split):
    """ Split data into training, validation, and test sets. """
    num_imgs = len(img_paths)
    
    indices = np.arange(num_imgs)
    np.random.shuffle(indices)
    
    train_end = int(train_split * num_imgs)
    val_end = train_end + int(val_split * num_imgs)
    
    train_indices = indices[:train_end]
    val_indices = indices[train_end:val_end]
    test_indices = indices[val_end:]
    full_indices = indices[:]
        
    train_paths = [img_paths[i] for i in train_indices]
    val_paths   = [img_paths[i] for i in val_indices]
    test_paths  = [img_paths[i] for i in test_indices]
    full_paths  = [img_paths[i] for i in full_indices]  
    
    train_labels = [labels[i] for i in train_indices]
    val_labels   = [labels[i] for i in val_indices]
    test_labels  = [labels[i] for i in test_indices]
    full_labels  = [labels[i] for i in full_indices]
    
    return (full_paths, full_labels), (train_paths, train_labels), (val_paths, val_labels), (test_paths, test_labels)

#------------------------------------------------------------------------

def create_tensor_dataset(ds_arc, img_paths, labels, img_size, labels_dict, no_space=None):
    """ Create a TensorDataset from image paths and labels. """
    num_imgs = len(img_paths)
    ds_imgs = np.empty((num_imgs, 1, img_size, img_size), dtype=np.float32)
    ds_lbls = np.empty((num_imgs), int)
    
    transform = transforms.Compose([
        transforms.Grayscale(),  # Convert image to grayscale
        transforms.Resize((img_size, img_size)),  # Resize image
        transforms.ToTensor(),  # Convert image to tensor
        # transforms.Normalize((0.5,), (0.5,))  # Normalize image to [-1, 1] (if needed)
    ])
    
    for i, img_path in enumerate(img_paths):
    
      if img_path == 'space' :   
        ds_imgs[i] = 0 # space image (all zeros)
        ds_lbls[i] = labels_dict['_'] # Space is represented by underscore charterer and a blank (missing hand) image
   
      else :
      
        try:

            img_data = ds_arc.read(img_path)
            img_dataEnc = io.BytesIO(img_data)
            img = Image.open(img_dataEnc)
            
            image = transform(img)
            
            # Quantize scaling input images from to 0 to 255                        
            ds_imgs_np = image.numpy()
            scale_min = np.min(ds_imgs_np)
            scale_max = np.max(ds_imgs_np)
            ds_imgs_np = np.round((ds_imgs_np-scale_min)*(256/(scale_max-scale_min)))  
            ds_imgs_np = np.clip(ds_imgs_np,0,255) # to be safe clamp at 0-255
            # End of quantize scaling
                                
            ds_imgs[i] = ds_imgs_np # image.numpy()
            ds_lbls[i] = labels[i]
            
        except Exception as e:
            print(f"Error processing image {img_path}: {e}")
            # continue
            exit()
                
    ds_imgs = np.squeeze(ds_imgs, axis=1)
    
    num_dict_labels = len(labels_dict)
    
    if not no_space :
    
         num_space_imgs =  ds_imgs.shape[0]//num_dict_labels
    
         space_lbl =  np.full_like(ds_lbls[0],labels_dict['_'])         
         space_labels = np.stack([space_lbl] * num_space_imgs, axis=0)                
         ds_lbls = np.concatenate((ds_lbls, space_labels),axis=0)  
         
         space_img =  np.full_like(ds_imgs[0],0)                
         space_images = np.stack([space_img] * num_space_imgs, axis=0)              
         ds_imgs = np.concatenate((ds_imgs, space_images),axis=0)  

    pt_tensor_imgs = torch.tensor(ds_imgs)
    pt_tensor_lbls = torch.tensor(ds_lbls, dtype=torch.long)
       
    return TensorDataset(pt_tensor_imgs, pt_tensor_lbls)

#------------------------------------------------------------------------

def gen_labels_dict(no_space=False,non_reduced_mode=False) :

    digits = list(map(chr, range(ord('0'), ord('9')+1)))
    small_letters = list(map(chr, range(ord('a'), ord('z')+1)))

    if non_reduced_mode:
      labels_list = digits + small_letters
    else:
      labels_list = small_letters  # No digits
      
    if not no_space :
      labels_list += '_' # Space is represented by underscore charterer and a blank (missing hand) image
       
    labels_dict = {} 
    for i in range(len(labels_list)) :
        labels_dict[labels_list[i]] = i
        
    return labels_dict, labels_list

#------------------------------------------------------------------------

def gen_pt_ds(args,ds_arc, train_split, val_split, test_split, output_dir):
    print('Generating datasets...')
    
    
    labels_dict,labels_list = gen_labels_dict(args.no_space, args.non_reduced_mode)
     
    img_paths, labels = process_images(labels_dict, ds_arc, args.img_size)
    
    (full_paths,full_labels),(train_paths,train_labels),(val_paths,val_labels),(test_paths,test_labels) = split_data(img_paths,labels,train_split,val_split,test_split)
             
        
    train_dataset = create_tensor_dataset(ds_arc, train_paths, train_labels, args.img_size, labels_dict, args.no_space)
    val_dataset   = create_tensor_dataset(ds_arc, val_paths,   val_labels,   args.img_size, labels_dict, args.no_space)
    test_dataset  = create_tensor_dataset(ds_arc, test_paths,  test_labels,  args.img_size, labels_dict, args.no_space)
    full_dataset  = create_tensor_dataset(ds_arc, full_paths,  full_labels,  args.img_size, labels_dict, args.no_space)
        
    # print(f'Labels names: {labels_list}')
    
    torch.save(dict(
        pt_ds=train_dataset,
        lnbi=labels_list,
        imgp=train_paths)
    , os.path.join(output_dir, 'slr_ds_train.pt'))
    
    torch.save(dict(
        pt_ds=val_dataset,
        lnbi=labels_list,
        imgp=val_paths)
    , os.path.join(output_dir, 'slr_ds_val.pt'))

    torch.save(dict(
        pt_ds=test_dataset,
        lnbi=labels_list,
        imgp=test_paths)
    , os.path.join(output_dir, 'slr_ds_test.pt'))
          
    full_paths_list = list(full_paths)
        
    torch.save(dict(
        pt_ds=full_dataset,
        lnbi=labels_list,
        imgp=full_paths_list)
    , os.path.join(output_dir, 'slr_ds_full.pt'))

        
    print(f'Captured total {len(img_paths)} images')
    print(f'Split into {len(train_paths)} training, {len(val_paths)} validation, and {len(test_paths)} test images')

#------------------------------------------------------------------------

if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='Generate PyTorch dataset from sign language images')   
    ap.add_argument('-dsz'  , metavar='<data_set_zip_file>', default="slr_dataset_src.zip", type=str, help='dataset source file in zip format') 
    ap.add_argument('-o', metavar='<output_directory>', type=str, default="workspace", help='Directory where the output files will be saved')
    ap.add_argument('--train_split', type=float, default=0.7, help='Proportion of the data to use for training (default=0.7)')
    ap.add_argument('--val_split', type=float, default=0.15, help='Proportion of the data to use for validation (default=0.15)')
    ap.add_argument('--test_split', type=float, default=0.15, help='Proportion of the data to use for testing (default=0.15)')
    ap.add_argument('--img_size', type=int, default=32, help='Square Image Dimension (default=32)')
    ap.add_argument('--non_reduced_mode' , action='store_true' , help='non reduced mode (default False)')  
    ap.add_argument('--no_space' , action='store_true'  , help='do not add space labels (default False)') 
  
    args = ap.parse_args()
    
    print('Reading sign lang dataset source text file from %s' % args.dsz)
    ds_arc = zipfile.ZipFile(args.dsz, 'r')
 
    output_dir = args.o
    train_split = args.train_split
    val_split = args.val_split
    test_split = args.test_split
    
    assert train_split + val_split + test_split == 1.0, "The splits must sum to 1.0"
       
    gen_pt_ds(args, ds_arc, train_split, val_split, test_split, output_dir)
    
    ds_arc.close()


