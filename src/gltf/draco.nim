import
  draco/decoders,
  draco/types

export types

proc decodeDraco*(
  payload: string,
  attributes: seq[DracoDecodeAttribute]
): DracoDecodeResult =
  ## Decodes a KHR_draco_mesh_compression payload.
  decodeDracoPayload(payload, attributes)
