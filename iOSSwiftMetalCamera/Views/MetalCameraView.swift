//
//  MetalCameraView.swift
//  iOSSwiftMetalCamera
//
//  Created by Bradley Griffith on 12/30/14.
//  Copyright (c) 2014 Bradley Griffith. All rights reserved.
//

import CoreMedia

class MetalCameraView: UIView, NodeDelegate {

	var metalEnvironment: MetalEnvironmentController?
	var metalDevice: MTLDevice?
	
	var videoPlane: Plane?
	
	var rgbShiftPipeline: MTLRenderPipelineState!
	var compositePipeline: MTLRenderPipelineState!
	
	var textureWidth: UInt?
	var textureHeight: UInt?
	var unmanagedTextureCache: Unmanaged<CVMetalTextureCache>?
	var textureCache: CVMetalTextureCacheRef?
	let worldZFullVideo: Float = -1.456 // World model matrix z position for full-screen video plane.
	
	var videoOutputTexture: MTLTexture?
	var videoTextureBuffer: MTLRenderPassDescriptor?
	var currentFrameBuffer: MTLRenderPassDescriptor?
	
	var showShader:Bool = false
	
	
	/* Lifecycle
	------------------------------------------*/
	
	override init(frame: CGRect) {
		super.init(frame: frame)
		
		_setup()
	}
	
	required init(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)
		
		_setup()
	}
	
	private func _setup() {
		_setupMetalEnvironment()
		
		_createTextureCache()
		_createRenderBufferObjects()
		_createRenderPipelineStates()
		_createOutputTextureForVideoPlane()
		_setListeners()
		
		metalEnvironment!.run()
	}
	
	
	/* Private Instance Methods
	------------------------------------------*/
	
	private func _setupMetalEnvironment() {
		metalEnvironment = MetalEnvironmentController(view: self)
		
		metalDevice = metalEnvironment!.device
	}
	
	private func _createTextureCache() {
		//  Use a CVMetalTextureCache object to directly read from or write to GPU-based CoreVideo image buffers
		//    in rendering or GPU compute tasks that use the Metal framework. For example, you can use a Metal
		//    texture cache to present live output from a device’s camera in a 3D scene rendered with Metal.
		CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &unmanagedTextureCache)
		
		textureCache = unmanagedTextureCache!.takeRetainedValue()
	}
	
	private func _createOutputTextureForVideoPlane() {
		let width = 1280
		let height = 720
		let format = videoPlane!.texture?.pixelFormat
		let desc = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(format!, width: width, height: height, mipmapped: true)
		videoOutputTexture = metalDevice!.newTextureWithDescriptor(desc)
		
		let texture = METLTexture(resourceName: "black", ext: "png")
		texture.finalize(metalDevice!, flip: true)
		
		videoTextureBuffer = MTLRenderPassDescriptor()
		videoTextureBuffer!.colorAttachments[0].texture = videoOutputTexture
		videoTextureBuffer!.colorAttachments[0].loadAction = MTLLoadAction.Load
		videoTextureBuffer!.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1.0)
		videoTextureBuffer!.colorAttachments[0].storeAction = MTLStoreAction.Store
	}
	
	private func _createRenderBufferObjects() {
		// Create our scene objects.
		videoPlane = Plane(device: metalDevice!)
		videoPlane?.delegate = self

		var texture = METLTexture(resourceName: "black", ext: "png")
		texture.format = MTLPixelFormat.BGRA8Unorm
		texture.finalize(metalDevice!, flip: false)
		videoPlane!.samplerState = _generateSamplerStateForTexture(metalDevice!)
		videoPlane!.texture = texture.texture
		
		metalEnvironment!.pushObjectToScene(videoPlane!)
	}
	
	private func _generateSamplerStateForTexture(device: MTLDevice) -> MTLSamplerState? {
		var pSamplerDescriptor:MTLSamplerDescriptor? = MTLSamplerDescriptor();
		
		if let sampler = pSamplerDescriptor
		{
			sampler.minFilter             = MTLSamplerMinMagFilter.Nearest
			sampler.magFilter             = MTLSamplerMinMagFilter.Nearest
			sampler.mipFilter             = MTLSamplerMipFilter.NotMipmapped
			sampler.maxAnisotropy         = 1
			sampler.sAddressMode          = MTLSamplerAddressMode.ClampToEdge
			sampler.tAddressMode          = MTLSamplerAddressMode.ClampToEdge
			sampler.rAddressMode          = MTLSamplerAddressMode.ClampToEdge
			sampler.normalizedCoordinates = true
			sampler.lodMinClamp           = 0
			sampler.lodMaxClamp           = FLT_MAX
		}
		else
		{
			println(">> ERROR: Failed creating a sampler descriptor!")
		}
		
		return device.newSamplerStateWithDescriptor(pSamplerDescriptor!)
	}
	
	private func _createRenderPipelineStates() {
		// Access any of the precompiled shaders included in your project through the MTLLibrary by calling device.newDefaultLibrary().
		//   Then look up each shader by name.
		let defaultLibrary = metalDevice!.newDefaultLibrary()!

		// Load all shaders needed for render pipeline
		let basicVert = defaultLibrary.newFunctionWithName("basic_vertex")
		let rgbShiftFrag = defaultLibrary.newFunctionWithName("rgb_shift_fragment")
		let compositeVert = defaultLibrary.newFunctionWithName("composite_vertex")
		let compositeFrag = defaultLibrary.newFunctionWithName("composite_fragment")
		
		// Setup pipeline
		let desc = MTLRenderPipelineDescriptor()
		var pipelineError : NSError?
		
		desc.label = "Composite"
		desc.vertexFunction = compositeVert
		desc.fragmentFunction = compositeFrag
		desc.colorAttachments[0].pixelFormat = .BGRA8Unorm
		compositePipeline = metalDevice!.newRenderPipelineStateWithDescriptor(desc, error: &pipelineError)
		if !(compositePipeline != nil) {
			println("Failed to create pipeline state, error \(pipelineError)")
		}
		
		desc.label = "RGBShift"
		desc.vertexFunction = basicVert
		desc.fragmentFunction = rgbShiftFrag
		desc.colorAttachments[0].pixelFormat = .BGRA8Unorm
		rgbShiftPipeline = metalDevice!.newRenderPipelineStateWithDescriptor(desc, error: &pipelineError)
		if !(rgbShiftPipeline != nil) {
			println("Failed to create pipeline state, error \(pipelineError)")
		}
	}
	
	private func _setListeners() {
		let panRecognizer = UIPanGestureRecognizer(target: self, action: "panGesture:")
		self.addGestureRecognizer(panRecognizer)
	}
	
	private func _currentFrameBufferForDrawable(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
		if (currentFrameBuffer == nil) {
			currentFrameBuffer = MTLRenderPassDescriptor()
			currentFrameBuffer!.colorAttachments[0].texture = drawable.texture
			currentFrameBuffer!.colorAttachments[0].loadAction = MTLLoadAction.Clear
			currentFrameBuffer!.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1)
			currentFrameBuffer!.colorAttachments[0].storeAction = MTLStoreAction.Store
		}
		
		return currentFrameBuffer!
	}
	
	private func _configureComputeEncoders(commandBuffer: MTLCommandBuffer, node: Node, drawable: CAMetalDrawable) {
	}
	
	private func _configureRenderEncoders(commandBuffer: MTLCommandBuffer, node: Node, drawable: CAMetalDrawable) {
		if (node == videoPlane) {
			
			// NOTE:
			//   The use of multiple passes here is to display how one could use multiple passes to effect
			//   and reuse a single texture. Multiple passes wouldnt be totally necessary in a real app for 
			//   our very basic needs here.
			
			
			// Start first pass
			var firstPassEncoder = commandBuffer.renderCommandEncoderWithDescriptor(videoTextureBuffer!)!
			
			/* Test Render Encoding
			------------------------------------------*/
			firstPassEncoder.pushDebugGroup("RGBShift render")
			firstPassEncoder.setRenderPipelineState(rgbShiftPipeline!)
			firstPassEncoder.setVertexBuffer(videoPlane!.vertexBuffer, offset: 0, atIndex: 0)
			firstPassEncoder.setFragmentTexture(videoPlane?.texture, atIndex: 0)
			firstPassEncoder.setFragmentSamplerState(videoPlane!.samplerState!, atIndex: 0)
			firstPassEncoder.setCullMode(MTLCullMode.None)
			
			// Set metadata buffer
			var metaDataBuffer = metalDevice!.newBufferWithBytes(&showShader, length: 1, options: MTLResourceOptions.OptionCPUCacheModeDefault)
			firstPassEncoder.setFragmentBuffer(metaDataBuffer, offset: 0, atIndex: 0)
			
			// Draw primitives
			firstPassEncoder.drawPrimitives(
				.Triangle,
				vertexStart: 0,
				vertexCount: videoPlane!.vertexCount,
				instanceCount: videoPlane!.vertexCount / 3
			)
			
			firstPassEncoder.popDebugGroup()
			/* ---------------------------------------*/
			
			firstPassEncoder.endEncoding()
			
			
			// Start second pass
			var secondPassEncoder = commandBuffer.renderCommandEncoderWithDescriptor(_currentFrameBufferForDrawable(drawable))!
			
			/* Composite Render Encoding
			------------------------------------------*/
			secondPassEncoder.pushDebugGroup("Composite render")
			secondPassEncoder.setRenderPipelineState(compositePipeline!)
			secondPassEncoder.setVertexBuffer(videoPlane!.vertexBuffer, offset: 0, atIndex: 0)
			secondPassEncoder.setFragmentTexture(videoOutputTexture, atIndex: 0)
			secondPassEncoder.setFragmentSamplerState(videoPlane!.samplerState!, atIndex: 0)
			secondPassEncoder.setCullMode(MTLCullMode.None)
			
			// Setup uniform buffer
			var worldMatrix = metalEnvironment?.worldModelMatrix
			var projectionMatrix = metalEnvironment?.projectionMatrix
			secondPassEncoder.setVertexBuffer(videoPlane?.sceneAdjustedUniformsBufferForworldModelMatrix(worldMatrix!, projectionMatrix: projectionMatrix!), offset: 0, atIndex: 1)
			
			// Draw primitives
			secondPassEncoder.drawPrimitives(
				.Triangle,
				vertexStart: 0,
				vertexCount: videoPlane!.vertexCount,
				instanceCount: videoPlane!.vertexCount / 3
			)
			
			secondPassEncoder.popDebugGroup()
			/* ---------------------------------------*/
			
			secondPassEncoder.endEncoding()
			
			
			//videoTextureBuffer = nil
			currentFrameBuffer = nil
		}
	}
	
	
	/* Public Instance Methods
	------------------------------------------*/
	
	func panGesture(sender: UIPanGestureRecognizer) {
		let translation = sender.translationInView(sender.view!)
		var newXAngle = (Float)(translation.y)*(Float)(M_PI)/180.0
		metalEnvironment!.cameraXAngle += newXAngle
		
		var newYAngle = (Float)(translation.x)*(Float)(M_PI)/180.0
		metalEnvironment!.cameraYAngle += newYAngle
	}
	
	func toggleShader(shouldShowShader: Bool) {
		showShader = shouldShowShader
	}
	
	func updateTextureFromSampleBuffer(sampleBuffer: CMSampleBuffer!) {
		var pixelBuffer: CVImageBufferRef = CMSampleBufferGetImageBuffer(sampleBuffer)!
		var sourceImage: CIImage = CIImage(CVPixelBuffer: pixelBuffer)
		
		var sourceExtent: CGRect = sourceImage.extent()
		var sourceAspect: CGFloat = sourceExtent.size.width / sourceExtent.size.height
		var previewAspect: CGFloat = self.bounds.size.width  / self.bounds.size.height
		
		if (sourceAspect > previewAspect) {
			videoPlane!.scaleX = Float(sourceAspect)
			videoPlane!.scaleY = 1.0
		} else {
			videoPlane!.scaleX = 1.0
			videoPlane!.scaleY = Float(1.0 / sourceAspect)
		}
		videoPlane!.positionZ = worldZFullVideo
		
		var texture: MTLTexture
		
		textureWidth = CVPixelBufferGetWidth(pixelBuffer)
		textureHeight = CVPixelBufferGetHeight(pixelBuffer)
		
		var pixelFormat: MTLPixelFormat = MTLPixelFormat.BGRA8Unorm
		
		var unmanagedTexture: Unmanaged<CVMetalTexture>?
		var status: CVReturn = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, pixelFormat, textureWidth!, textureHeight!, 0, &unmanagedTexture)
		// Note: 0 = kCVReturnSuccess
		if (status == 0) {
			texture = CVMetalTextureGetTexture(unmanagedTexture?.takeRetainedValue());
			videoPlane!.texture! = texture
		}
	}
	
	
	/* NodeDelegate Delegate Methods
	------------------------------------------*/
	
	func configureCommandBuffer(commandBuffer: MTLCommandBuffer, node: Node, drawable: CAMetalDrawable) {
		_configureComputeEncoders(commandBuffer, node: node, drawable: drawable)
		_configureRenderEncoders(commandBuffer, node: node, drawable: drawable)
	}
	
}