# Pytorch front-end

# Open git bash terminal at clone root

```bash
cd sw/apps/slr_shared/pt
```

## Generate the dataset
```bash
python gen_slr_ptds.py 
```

## Training
```bash
python slr_train.py -scf slr_conf1
```

## Inference with floating point params (non mnx quantized)
```bash
python slr_inference.py -wfn workspace/slr_tmw.pt -nt 5000

# With batch norm folding (in case args.bn=True applied) should deliver same results.
python slr_inference.py -wfn workspace/slr_tmw.pt -nt 5000 -bnf
```
## Reporting Model Statistics
Following command wil report the model parameters and and MAC (Multiply-Accumulate) operations count.
```bash
python report_model_params.py -wfn workspace/slr_tmw.pt
``` 

## Convert model params to k5x hex format
python gen_mnx_model_params_file.py -wfn workspace/slr_tmw.pt -sapl 0.65 -qpt


## run pytorch in mannix quantized mode
python slr_inference.py -wfn workspace/slr_tmw_mnx_params.pt -nt 5000 -mnx

## Convert test dataset to Mannix format
```bash
python ds_pt_to_mnx.py -gdn slr
```

## Test on k5x simulation environment
TODO: Formlize and add to setup , + RC2 Support 

cd $MY_K5_PROJ/sim  

Terminal #1 :  

enics:   
export K5X_SLR="/project/generic/users/$USER/ws/k5x_slr"
launch_k5_app -ard $K5X_SLR/sw/apps  -asl slr_shared slr_base -cmp
launch_k5_app -ard $K5X_SLR_ROOT/sw/apps  -asl slr_shared slrx  -ccd1 XON -itr 16

Terminal #2 :

export K5X_SLR_ROOT="/project/generic/users/$USER/ws/k5x_slr"
TODO:  change to k5_slr once available  
launch_k5_sim slrx

## Test on k5x FPGA Board

launch_k5_app -ard $K5X_WIN/k5x_slr/sw/apps -asl slr_shared slr_base  -cmp


TO BE CONTINUED

## HLCM SW only execution

launch_k5_app -ard $K5X_WIN/k5x_slr/sw/apps  -asl slr_shared slr_base  -hlcm 

launch_k5_app -ard \$K5X_SLR_ROOT/sw/apps  -asl slr_shared slrx  -hlcm -itr 16

TO BE CONTINUED

## Troubleshooting

pip3.9 install pillow --user  
pip3.9 install  torchvision --user
pip3.9 install  scipy --user






