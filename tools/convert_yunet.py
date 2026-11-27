"""Rebuild models/YuNet.mlmodel from OpenCV Zoo's March 2023 YuNet ONNX.

Use coremltools 8.3.0 and onnx 1.17.0. The convolution weights are copied
without retraining or quantization. Export CHW heads before the ONNX layout
transposes. FaceBoxes.swift reads those planes directly.
"""
from pathlib import Path
import hashlib
import sys

import coremltools as ct
import onnx
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from onnx import helper, numpy_helper

sha = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
source = Path(sys.argv[1]).read_bytes()
if hashlib.sha256(source).hexdigest() != sha:
    raise ValueError("Expected OpenCV Zoo face_detection_yunet_2023mar.onnx")
model = onnx.load_model_from_string(source)
weights = {tensor.name:numpy_helper.to_array(tensor) for tensor in model.graph.initializer}
producer = {name:n for n in model.graph.node for name in n.output}
outputs = [(f"{head}_{stride}",datatypes.Array(channels,640//stride,640//stride))
           for stride in (8,16,32) for head,channels in (("cls",1),("obj",1),("bbox",4),("kps",10))]
net = NeuralNetworkBuilder([("input",datatypes.Array(3,640,640))],outputs,
                           disable_rank5_shape_mapping=True,use_float_arraytype=True)
for node in model.graph.node:
    name, args, out = node.output[0], node.input, node.output[0]
    attr = {a.name:helper.get_attribute_value(a) for a in node.attribute}
    kind = node.op_type
    if kind == "Conv":
        w = weights[args[1]]
        n,c,h,k = w.shape
        sy,sx = attr["strides"]
        top,left,bottom,right = attr["pads"]
        net.add_convolution(name,c,n,h,k,sy,sx,"valid",attr["group"],w.transpose(2,3,1,0),
                            weights[args[2]],True,input_name=args[0],output_name=out,
                            padding_top=top,padding_left=left,padding_bottom=bottom,padding_right=right)
    elif kind == "Relu":
        net.add_activation(name,"RELU",args[0],out)
    elif kind == "MaxPool":
        assert attr["pads"] == [0,0,0,0] and attr["ceil_mode"] == 0
        net.add_pooling(name,*attr["kernel_shape"],*attr["strides"],"MAX","VALID",args[0],out)
    elif kind == "Resize":
        assert attr["mode"] == b"nearest" and list(weights[args[2]]) == [1,1,2,2]
        net.add_upsample(name,2,2,args[0],out)
    elif kind == "Add":
        net.add_elementwise(name,list(args),out,"ADD")
    elif kind not in ("Transpose","Reshape","Sigmoid"):
        raise ValueError(kind)
for name,_ in outputs:
    reshape = producer[name]
    scored = reshape.op_type == "Sigmoid"
    if scored:
        reshape = producer[reshape.input[0]]
    transpose = producer[reshape.input[0]]
    assert reshape.op_type == "Reshape" and transpose.op_type == "Transpose"
    assert list(helper.get_attribute_value(transpose.attribute[0])) == [0,2,3,1]
    if scored: net.add_activation(name,"SIGMOID",transpose.input[0],name)
    else: net.add_copy(name,transpose.input[0],name)
net.set_pre_processing_parameters(image_input_names=["input"],is_bgr=True)
net.spec.description.metadata.author = "Shiqi Yu et al. (YuNet, OpenCV Zoo)"
net.spec.description.metadata.license = "MIT; see licenses/yunet.txt"
net.spec.description.metadata.userDefined["sourceSHA256"] = sha
ct.utils.save_spec(net.spec,sys.argv[2])
