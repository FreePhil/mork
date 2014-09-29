require 'mork/grid_omr'
require 'mork/mimage'
require 'mork/mimage_list'
require 'mork/npatch'

module Mork
  class SheetOMR
    def initialize(im, grom=nil)
      @raw   = case im
               when String
                 Mimage.new im
               when Mork::Mimage
                 im
               else
                 raise "A new sheet requires either a Mimage or the name of the source image file, but it was a: #{im.class}"
               end
      @grom = case grom
               when String, Hash, NilClass
                 GridOMR.new @raw.width, @raw.height, grom
               else
                 raise 'Invalid argument in SheetOMR initialization'
               end
      @rm   = {}
      @rmsa = {}
      @ok_reg = register @raw
    end
    
    def valid?
      @ok_reg
    end
    
    # barcode
    # 
    # returns the sheet barcode as an integer
    def barcode
      return if not_registered
      barcode_string.to_i(2)
    end
    
    # barcode_string
    # 
    # returns the sheet barcode as a string of 0s and 1s. The string is barcode_bits
    # bits long, with most significant bits to the left
    def barcode_string
      return if not_registered
      cs = @grom.barcode_bits.times.inject("") { |c, v| c << barcode_bit_value(v) }
      cs.reverse
    end
    
    # marked?(question, choice)
    # 
    # returns true if the specified question/choice cell has been darkened
    # false otherwise
    def marked?(q, c)
      return if not_registered
      shade_of(q, c) < choice_threshold
    end
    
    # TODO: define method ‘mark’ to retrieve the choice array for a single item
    
    # mark_array(range)
    # 
    # returns an array of arrays of marked choices.
    # takes either a range of questions, an array of questions, or a fixnum,
    # in which case the choices for the first n questions will be returned.
    # if called without arguments, all available choices will be evaluated
    def mark_array(r = nil)
      return if not_registered
      question_range(r).collect do |q|
        cho = []
        (0...@grom.max_choices_per_question).each do |c|
          cho << c if marked?(q, c)
        end
        cho
      end
    end
    
    def mark_logical_array(r = nil)
      return if not_registered
      question_range(r).collect do |q|
        (0...@grom.max_choices_per_question).collect {|c| marked?(q, c)}
      end
    end
    
    # ================
    # = HIGHLIGHTING =
    # ================
    
    def outline(cells)
      return if not_registered
      @crop.outline! array_of cells
    end
    
    def highlight_all
      return if not_registered
      cells = (0...@grom.max_questions).collect { |i| (0...@grom.max_choices_per_question).to_a }
      @crop.highlight_cells! array_of cells
      @crop.highlight_cells! @grom.calibration_cell_areas
      @crop.highlight_rect! [@grom.ink_black_area, @grom.paper_white_area]
      @crop.highlight_rect! @grom.barcode_bit_areas
    end
    
    def highlight_marked
      return if not_registered
      @crop.highlight_cells! array_of mark_array
    end
    
    def highlight_barcode
      return if not_registered
      @grom.barcode_bits.times do |bit|
        if barcode_string.reverse[bit] == '1'
          @crop.highlight_rect! @grom.barcode_bit_area bit+1
        end
      end
    end
    
    def highlight_reg_area
      @raw.highlight_rect! [@rmsa[:tl], @rmsa[:tr], @rmsa[:br], @rmsa[:bl]]
      return if not_registered
      @raw.join! [@rm[:tl],@rm[:tr],@rm[:br],@rm[:bl]]
    end

    def write(fname)
      return if not_registered
      @crop.write(fname)
    end
    
    def write_raw(fname)
      @raw.write(fname)
    end
    
    # =================================
    # = compute shading with NPatches =
    # =================================
    def shade_of(q, c)
      naverage @grom.choice_cell_area(q, c)
    end
    
  private
  
    def array_of(cells)
      out = []
      cells.each_with_index do |q, i|
        q.each do |c|
          out << @grom.choice_cell_area(i, c)
        end
      end
      out
    end

    def question_range(r)
      if r.nil?
        (0...@grom.max_questions)
      elsif r.is_a? Fixnum
        (0...r)
      elsif r.is_a? Array
        r
      else
        raise "Invalid argument"
      end
    end
    
    def barcode_bit_value(i)
      shade_of_barcode_bit(i) < barcode_threshold ? "1" : "0"
    end
    
    def shade_of_barcode_bit(i)
      naverage @grom.barcode_bit_area i+1
    end

    def barcode_threshold
      @barcode_threshold ||= (paper_white + ink_black) / 2
    end
    
    def choice_threshold
      @choice_threshold ||= (ccmeans.mean - ink_black) * 0.9 + ink_black
    end
    
    def ccmeans
      @calcmeans ||= @grom.calibration_cell_areas.collect { |c| naverage c }
    end
    
    def paper_white
      @paper_white ||= naverage @grom.paper_white_area
    end
    
    def ink_black
      @ink_black ||= naverage @grom.ink_black_area
    end
    
    def shade_of_blank_cells
      # @grom.
    end
    
    # ================
    # = Registration =
    # ================
    
    # this method uses a 'stretch' strategy, i.e. where the image after
    # registration has the same size in pixels as the original scanned file
    def register(img)
      # find the XY coordinates of the 4 registration marks
      @rm[:tl] = reg_centroid_on(img, :tl)
      @rm[:tr] = reg_centroid_on(img, :tr)
      @rm[:br] = reg_centroid_on(img, :br)
      @rm[:bl] = reg_centroid_on(img, :bl)
      return false if @rm.any? { |k,v| v[:status] != :ok }
      # stretch the 4 points to fit the original size and return the resulting image
      @crop = img.stretch [
        @rm[:tl][:x], @rm[:tl][:y],         0,          0,
        @rm[:tr][:x], @rm[:tr][:y], img.width,          0,
        @rm[:br][:x], @rm[:br][:y], img.width, img.height,
        @rm[:bl][:x], @rm[:bl][:y],         0, img.height
      ]
      true
    end
    
    # returns the centroid of the dark region within the given area
    # in the XY coordinates of the entire image
    def reg_centroid_on(img, corner)
      1000.times do |i|
        @rmsa[corner] = @grom.rm_search_area(corner, i)
        cx, cy = NPatch.new(img.crop(@rmsa[corner])).dark_centroid
        if cx.nil?
          status = :insufficient_contrast  
        elsif (cx < @grom.rm_edgy_x) or
              (cy < @grom.rm_edgy_y) or
              (cy > @rmsa[corner][:h] - @grom.rm_edgy_y) or
              (cx > @rmsa[corner][:w] - @grom.rm_edgy_x)
          status = :edgy
        else
          return {status: :ok, x: cx + @rmsa[corner][:x], y: cy + @rmsa[corner][:y]}
        end
        return {status: status, x: nil, y: nil} if @rmsa[corner][:w] > @grom.rm_max_search_area_side
      end
    end
    
    def naverage(where)
      NPatch.new(@crop.crop where).average
    end
    
    def not_registered
      unless @ok_reg
        puts "---=={ Unregistered image. Reason: '#{@rm.inspect}' }==---"
        true
      end
    end
  end
end