import sys
import argparse
import torch
from torch.utils.data import DataLoader
from torch.serialization import safe_globals
from torch.utils.data import TensorDataset

sys.path.append('../../../utils/pymnx/')
import pt_train as ptt

# # Load preprocessed datasets
# def load_dataset(dataset_path):
#     print(f"Loading dataset from {dataset_path}")
#     data = torch.load(dataset_path)
#     return data['pt_ds']

# Main function to handle the training
def main():
    ap = argparse.ArgumentParser(description='pt train', formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument('-scf', metavar='<scf_conf_name>', type=str, default="slr_conv_conf1", help='Training configuration file')
    # ap.add_argument('-train', metavar='<train_set_path>', type=str, default="workspace/slr_train.pt", required=True, help='Path to the training set (.pt file)')
    # ap.add_argument('-val', metavar='<val_set_path>', type=str, default="workspace/slr_val.pt", required=True, help='Path to the validation set (.pt file)')
    args = ap.parse_args()

    train_path = "workspace/slr_train.pt"
    val_path = "workspace/slr_val.pt"

    workspace_path = './workspace/'

    # Load datasets
    with safe_globals([TensorDataset]):
       train_set = torch.load(train_path)
       val_set = torch.load(val_path)
    
    # # Optionally, create DataLoaders (adjust batch size as necessary)
    # train_loader = DataLoader(train_set, batch_size=32, shuffle=True)
    # val_loader = DataLoader(val_set, batch_size=32, shuffle=False)
    
    # Invoke the training process using the ptt module
    ptt.invoke(workspace_path=workspace_path, scf=args.scf, train_set=train_set, val_set=val_set)

if __name__ == '__main__':
    main()

