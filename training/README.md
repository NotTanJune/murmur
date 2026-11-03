# Fine-tuning Bark Clean's decoder on your dictation

1. In Murmur, Settings → Training → Export. A zip lands in
   `~/Library/Application Support/Murmur/Training/`.
2. Open `bark_decoder_finetune.ipynb` in Google Colab (free T4 is enough). Upload the zip
   when the first cell asks.
3. Run all cells. The notebook stops without exporting if the fine-tune is not better than
   stock on your held-out clips or drifts on replay clips; the tables tell you why.
4. Download `bark-decoder-<date>.zip`, unzip, and in Murmur choose Install fine-tuned
   decoder… and pick the folder. Switch Decoder to it. Revert with Stock any time.

Only the decoder and joint (35 MB) are trained. The encoder stays the stock low-bit build,
so acoustics do not change; what improves is which words the model writes for sounds it
already hears correctly.

## Verify the Core ML export on the first real run

Cells 7 and 8 were written against the stock package's documented contract and have not
been run. Check them once:

- Decoder: inputs `targets` Int32 [1,1], `target_length` Int32 [1], `h_in` and `c_in`
  Float32 [2,1,640]; outputs `decoder` Float32 [1,640,1], `h_out`, `c_out` Float32 [2,1,640].
- JointDecisionv3: inputs `encoder_step` Float32 [1,1024,1], `decoder_step` Float32
  [1,640,1]; outputs `token_id`, `duration` Int32 [1,1,1], `token_prob` Float32 [1,1,1]
  (the max token logit, not softmaxed), `top_k_ids` Int32 [1,1,1,64], `top_k_logits`
  Float32 [1,1,1,64].
- Cell 7 gives the Decoder model the embedding and the two-layer LSTM only, and the joint
  model both projections plus the head. That matches the stock package: its
  `Decoder.mlmodelc/model.mil` holds `module_prediction_embed_weight` [8193, 640] and the
  LSTM weights and nothing else, and `JointDecisionv3.mlmodelc/model.mil` holds
  `joint_module_enc_weight` [640, 1024], `joint_module_pred_weight` [640, 640] and
  `joint_module_joint_net_2_weight` [8198, 640] (8193 tokens plus 5 durations). Cell 7's
  parity assertion checks the split against the Hugging Face model's own joint.

Then compile and run `Murmur --decoder-check <folder> <audio>` on the Mac. A load failure
there means an output name or dtype differs from the stock package's `metadata.json`.
