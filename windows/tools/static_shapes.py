"""Fixes a BERT-style ONNX model's inputs to 1 x SEQ tokens (the Snapdragon NPU needs fixed
shapes), whatever its dynamic dimensions are called, and prints what the app will see.

Usage: python static_shapes.py model.onnx 128
"""
import sys

import onnx


def fix(dims, seq):
    # Dynamic dimensions in order: batch, then sequence; fixed ones (like 384) stay as they are.
    wanted = [1, seq]
    for d in dims:
        if not d.HasField("dim_value") and wanted:
            d.ClearField("dim_param")
            d.dim_value = wanted.pop(0)


def main(path, seq):
    model = onnx.load(path)
    graph = model.graph
    initializers = {i.name for i in graph.initializer}
    inputs = [i for i in graph.input if i.name not in initializers]
    for i in inputs:
        fix(i.type.tensor_type.shape.dim, seq)
    for o in graph.output:
        fix(o.type.tensor_type.shape.dim, seq)
    # Shapes inside the graph are worked out again from the fixed inputs.
    del graph.value_info[:]
    model = onnx.shape_inference.infer_shapes(model)
    onnx.checker.check_model(model)
    onnx.save(model, path)

    def shape(v):
        return [d.dim_value or d.dim_param for d in v.type.tensor_type.shape.dim]

    for i in inputs:
        print("input ", i.name, shape(i))
    for o in model.graph.output:
        print("output", o.name, shape(o))
    names = {i.name for i in inputs}
    if not names <= {"input_ids", "attention_mask", "token_type_ids"}:
        sys.exit(f"unexpected inputs {names}")
    if "last_hidden_state" not in {o.name for o in model.graph.output}:
        sys.exit("model has no last_hidden_state output")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]))
