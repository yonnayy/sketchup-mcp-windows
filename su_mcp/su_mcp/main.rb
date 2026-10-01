require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'

puts "MCP Extension loading..."

module SU_MCP
  PREF_SECTION = 'SU_MCP'.freeze

  def self.autostart?
    Sketchup.read_default(PREF_SECTION, 'autostart', true) ? true : false
  end

  def self.autostart=(value)
    Sketchup.write_default(PREF_SECTION, 'autostart', value ? true : false)
  end

  # House rules for every model built through MCP: which tag and which
  # material each kind of building element gets. See docs/STANDARDS.md.
  module Standards
    # kind => [tag, default material, [r, g, b], opacity]
    TABLE = {
      'referensi' => ['00-Referensi', nil, nil, 1.0],
      'dinding'   => ['01-Dinding', 'Dinding - Cat Putih', [240, 238, 230], 1.0],
      'lantai'    => ['02-Lantai', 'Lantai - Keramik', [200, 195, 185], 1.0],
      'pintu'     => ['03-Pintu', 'Pintu - Kayu', [140, 95, 60], 1.0],
      'jendela'   => ['04-Jendela', 'Jendela - Kaca', [150, 200, 220], 0.4],
      'atap'      => ['05-Atap', 'Atap - Genteng', [150, 70, 50], 1.0],
      'struktur'  => ['06-Struktur', 'Struktur - Beton', [170, 170, 170], 1.0],
      'tangga'    => ['07-Tangga', 'Tangga - Beton', [170, 170, 170], 1.0],
      'furnitur'  => ['08-Furnitur', 'Furnitur - Kayu', [180, 140, 100], 1.0],
      'tapak'     => ['09-Tapak', 'Tapak - Rumput', [120, 160, 90], 1.0],
      'anotasi'   => ['10-Anotasi', nil, nil, 1.0]
    }.freeze
    MATERIAL_NAME = /\A\S.* - \S/.freeze
    CUSTOM_TAG = /\A\d\d-\S/.freeze

    def self.row(kind)
      TABLE[kind.to_s] || raise("Unknown element kind #{kind.inspect}. Use one of: #{TABLE.keys.join(', ')}")
    end

    def self.tag(kind)
      Sketchup.active_model.layers.add(row(kind)[0])
    end

    # Returns the standard material for a kind, creating it on first use.
    # Pass name (and rgb) for another finish, e.g.
    #   material(:dinding, 'Dinding - Bata Ekspos', [165, 80, 60])
    def self.material(kind, name = nil, rgb = nil, opacity = nil)
      r = row(kind)
      name ||= r[1]
      return nil unless name
      raise "Material name #{name.inspect} must look like 'Elemen - Bahan'" unless name =~ MATERIAL_NAME
      materials = Sketchup.active_model.materials
      mat = materials[name]
      unless mat
        mat = materials.add(name)
        mat.color = Sketchup::Color.new(*(rgb || r[2] || [200, 200, 200]))
        # Only the kind's own default material inherits its opacity: another
        # finish for a window (a timber frame) must not come out like glass.
        mat.alpha = opacity || (name == r[1] ? r[3] : 1.0)
      end
      mat
    end

    # Creates one building element the standard way: a named group whose raw
    # geometry is Untagged, with the kind's tag and material on the group.
    #   SU_MCP.element('Atap', :atap, parent_group) { |ents| ents.add_face(...) }
    def self.element(name, kind, parent = nil, material_name = nil, rgb = nil)
      model = Sketchup.active_model
      target = parent ? parent.entities : model.active_entities
      previous = model.active_layer
      model.active_layer = model.layers[0]
      begin
        group = target.add_group
        group.name = name.to_s
        yield group.entities, group if block_given?
        group.layer = tag(kind)
        mat = material(kind, material_name, rgb)
        group.material = mat if mat
        group
      ensure
        model.active_layer = previous
      end
    end

    # Returns the top-level container group for one building, creating it when
    # it does not exist yet. Containers hold floors and elements; they carry
    # no tag and no material themselves.
    #   rumah = SU_MCP.container('Rumah Contoh')
    def self.container(name)
      model = Sketchup.active_model
      found = model.entities.grep(Sketchup::Group).find { |g| g.name == name.to_s }
      return found if found
      previous = model.active_layer
      model.active_layer = model.layers[0]
      begin
        group = model.entities.add_group
        group.name = name.to_s
        group
      ensure
        model.active_layer = previous
      end
    end

    def self.audit
      model = Sketchup.active_model
      return "AUDIT FAILED. No model is open." unless model
      untagged = model.layers[0]
      standard_tags = TABLE.values.map { |r| r[0] }
      unchecked_tags = [TABLE['referensi'][0], TABLE['anotasi'][0]]
      problems = []
      elements = 0
      containers = 0

      loose = model.entities.count { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }
      problems << "#{loose} loose edges/faces at the model root (put them in a named group)" if loose > 0

      walk = lambda do |entities, path, inherited|
        entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          inner = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
          name = e.name.to_s
          name = e.definition.name.to_s if name.empty? && e.is_a?(Sketchup::ComponentInstance)
          label = (path + [name.empty? ? "(unnamed ##{e.entityID})" : name]).join(' > ')
          problems << "#{label}: has no name" if name.empty?
          # Reference objects and plan annotations ("10-Anotasi <scene>") are not building elements.
          next if unchecked_tags.any? { |t| e.layer.name == t || e.layer.name.start_with?("#{TABLE['anotasi'][0]} ") }

          raw = inner.select { |x| x.is_a?(Sketchup::Face) || x.is_a?(Sketchup::Edge) }
          mat = e.material || inherited
          if e.material && e.material.name !~ MATERIAL_NAME
            problems << "#{label}: material '#{e.material.name}' is not named 'Elemen - Bahan'"
          end
          if raw.empty?
            containers += 1
          else
            elements += 1
            tagged = raw.count { |x| x.layer != untagged }
            problems << "#{label}: #{tagged} edges/faces inside carry a tag (raw geometry must stay Untagged)" if tagged > 0
            if e.layer == untagged
              problems << "#{label}: has no tag"
            elsif !standard_tags.include?(e.layer.name) && e.layer.name !~ CUSTOM_TAG
              problems << "#{label}: tag '#{e.layer.name}' is not a standard tag"
            end
            unless mat
              bare = raw.grep(Sketchup::Face).count { |f| f.material.nil? }
              problems << "#{label}: no material (#{bare} faces show the default colour)" if bare > 0
            end
          end
          walk.call(inner, path + [name], mat)
        end
      end
      walk.call(model.entities, [], nil)

      head = "#{elements} elements and #{containers} containers checked."
      if problems.empty?
        "AUDIT OK. #{head} All rules satisfied."
      else
        "AUDIT FAILED. #{head} #{problems.length} problem(s):\n- " + problems.first(40).join("\n- ")
      end
    end
  end

  # Measures the built model so it can be compared with the plan's dimensions.
  # See docs/MODELING.md ("Laporan akurasi").
  module Verify
    WALL_TAG = Standards::TABLE['dinding'][0]

    # Distance (inches) from origin along dir to the first wall face. Anything
    # that is not a wall (door leaf, glass, furniture, slab) is stepped over.
    def self.wall_hit(model, origin, dir)
      point = origin
      25.times do
        hit = model.raytest([point, dir], false)
        return nil unless hit
        hit_point, path = hit
        if path.any? { |e| e.respond_to?(:layer) && e.layer && e.layer.name == WALL_TAG }
          return origin.distance(hit_point).to_f
        end
        point = hit_point.offset(dir, 0.01)
      end
      nil
    end

    # Heights above the floor at which a measuring ray is cast. A single ray
    # would slip through a door or window opening and report the next room's
    # wall, so the nearest wall face found at any of these heights is used.
    # The top ray clears a 2.03 m door head but stays under a normal ceiling:
    # any higher and it would reach into the storey above and measure its walls.
    RAY_HEIGHTS = [0.05, 0.5, 1.0, 1.5, 2.0, 2.3].freeze

    # Clear distance in metres between the two wall faces either side of [x, y].
    def self.clear(model, x, y, z, angle)
      dir = Geom::Vector3d.new(Math.cos(angle), Math.sin(angle), 0)
      back = dir.reverse
      ahead = nil
      behind = nil
      RAY_HEIGHTS.each do |h|
        origin = Geom::Point3d.new(x.to_f.m, y.to_f.m, (z.to_f + h).m)
        a = wall_hit(model, origin, dir)
        b = wall_hit(model, origin, back)
        ahead = a if a && (ahead.nil? || a < ahead)
        behind = b if b && (behind.nil? || b < behind)
      end
      return nil unless ahead && behind
      (ahead + behind).to_m
    end

    # World-space extent in metres of all walls, optionally limited to groups
    # under a container with the given building and/or floor name.
    def self.overall(model, axis, building, floor)
      low = nil
      high = nil
      walk = lambda do |entities, tr, names|
        entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          inner = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
          here = names + [e.name.to_s]
          if e.layer.name == WALL_TAG
            next if building && !here.include?(building.to_s)
            next if floor && !here.include?(floor.to_s)
            box = e.bounds
            8.times do |i|
              corner = box.corner(i).transform(tr)
              value = axis == 1 ? corner.y : corner.x
              low = value if low.nil? || value < low
              high = value if high.nil? || value > high
            end
          else
            walk.call(inner, tr * e.transformation, here)
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, [])
      low ? (high - low).to_f.to_m : nil
    end

    def self.angle_of(axis)
      case axis
      when nil, "x", "X" then 0.0
      when "y", "Y" then Math::PI / 2
      else axis.to_f * Math::PI / 180
      end
    end

    def self.report(checks, tolerance = nil)
      model = Sketchup.active_model
      return "VERIFY FAILED. No model is open." unless model
      tolerance = (tolerance || 0.005).to_f
      rows = []
      (checks || []).each do |c|
        label = (c["label"] || "ukuran").to_s
        if c["overall"]
          axis = c["overall"].to_s.downcase == "y" ? 1 : 0
          rows << [label, c["expected"], overall(model, axis, c["building"], c["floor"])]
        elsif c["at"]
          x, y = c["at"]
          z = c["z"] || 0
          if c["expected"].is_a?(Array) || (c["expected"].nil? && c["axis"].nil?)
            want = c["expected"] || [nil, nil]
            rows << ["#{label} (arah x)", want[0], clear(model, x, y, z, 0.0)]
            rows << ["#{label} (arah y)", want[1], clear(model, x, y, z, Math::PI / 2)]
          else
            rows << [label, c["expected"], clear(model, x, y, z, angle_of(c["axis"]))]
          end
        else
          rows << [label, c["expected"], nil]
        end
      end
      return "VERIFY FAILED. No checks given." if rows.empty?

      good = 0
      compared = 0
      lines = rows.map do |label, expected, measured|
        if measured.nil?
          compared += 1 if expected
          "TIDAK TERUKUR  #{label}: no wall found on both sides (move the point, or check the model)"
        elsif expected.nil?
          "UKUR           #{label}: model #{format('%.3f', measured)} m"
        else
          compared += 1
          diff = measured - expected.to_f
          ok = diff.abs <= tolerance
          good += 1 if ok
          "#{ok ? 'OK            ' : 'SELISIH       '} #{label}: plan #{format('%.3f', expected.to_f)} m, " \
            "model #{format('%.3f', measured)} m (#{format('%+d', (diff * 1000).round)} mm)"
        end
      end
      head = if compared.zero?
               "VERIFY: #{rows.length} dimension(s) measured, nothing to compare."
             elsif good == compared
               "VERIFY OK. #{good} of #{compared} dimensions match the plan within #{(tolerance * 1000).round} mm."
             else
               "VERIFY FAILED. #{good} of #{compared} dimensions match the plan within #{(tolerance * 1000).round} mm."
             end
      head + "\n" + lines.join("\n")
    end
  end

  def self.verify_dimensions(checks, tolerance = nil)
    Verify.report(checks, tolerance)
  end

  # Dimensioned plan view: a top-down scene cut through the walls, with the
  # overall and clear room dimensions drawn in. See docs/MODELING.md.
  module Plan
    # Outside extent of the walls in metres: [xmin, xmax, ymin, ymax].
    def self.wall_box(model, building, floor)
      box = nil
      walk = lambda do |entities, tr, names|
        entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          here = names + [e.name.to_s]
          if e.layer.name == Verify::WALL_TAG
            next if building && !here.include?(building.to_s)
            next if floor && !here.include?(floor.to_s)
            8.times do |i|
              c = e.bounds.corner(i).transform(tr)
              x = c.x.to_f.to_m
              y = c.y.to_f.to_m
              box ||= [x, x, y, y]
              box[0] = x if x < box[0]
              box[1] = x if x > box[1]
              box[2] = y if y < box[2]
              box[3] = y if y > box[3]
            end
          else
            inner = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
            walk.call(inner, tr * e.transformation, here)
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, [])
      box
    end

    # Distance in metres from [x, y] to the nearest wall face along angle.
    def self.reach(model, x, y, z, angle)
      dir = Geom::Vector3d.new(Math.cos(angle), Math.sin(angle), 0)
      best = nil
      Verify::RAY_HEIGHTS.each do |h|
        d = Verify.wall_hit(model, Geom::Point3d.new(x.to_f.m, y.to_f.m, (z.to_f + h).m), dir)
        best = d if d && (best.nil? || d < best)
      end
      best ? best.to_m : nil
    end

    def self.build(spec)
      model = Sketchup.active_model
      raise "No model is open in SketchUp" unless model
      name = (spec["name"] || "Denah").to_s
      base_z = (spec["base_z"] || 0).to_f
      cut = base_z + (spec["cut_height"] || 1.2).to_f
      building = spec["building"]
      floor = spec["floor"]
      rooms = spec["rooms"] || []
      box = wall_box(model, building, floor)
      raise "No walls found (tag #{Verify::WALL_TAG}); build the floor plan first" unless box
      xmin, xmax, ymin, ymax = box
      warnings = []
      dims = 0

      model.start_operation("MCP: #{name}", true)
      begin
        unless spec.key?("set_units") && !spec["set_units"]
          units = model.options["UnitsOptions"]
          units["LengthFormat"] = 0     # decimal
          units["LengthUnit"] = 4       # metres
          units["LengthPrecision"] = 2
        end

        # Replace an earlier plan view of the same name.
        model.entities.grep(Sketchup::Group).select { |g| g.name == "Anotasi #{name}" }.each(&:erase!)
        model.entities.grep(Sketchup::SectionPlane).select { |s| s.name == name }.each(&:erase!)
        old_page = model.pages[name]
        model.pages.erase(old_page) if old_page

        # Scenes switch at once, so a screenshot taken right after is not mid-animation.
        model.options["PageOptions"]["ShowTransition"] = false

        # A scene to come back to, saved before anything is cut or hidden.
        if model.pages.count == 0
          model.entities.active_section_plane = nil
          model.pages.add("3D")
        end

        # Every plan view gets a tag of its own ("10-Anotasi <name>"), so each
        # scene can show its own dimensions and hide those of the other plans.
        annotation = model.layers.add("#{Standards::TABLE['anotasi'][0]} #{name}")
        previous_layer = model.active_layer
        model.active_layer = model.layers[0]
        notes = model.entities.add_group
        notes.name = "Anotasi #{name}"
        model.active_layer = previous_layer

        z = cut.m
        begin
          ents = notes.entities
          gap = 0.8.m
          ents.add_dimension_linear([xmin.m, ymin.m, z], [xmax.m, ymin.m, z], [0, -gap, 0])
          ents.add_dimension_linear([xmin.m, ymin.m, z], [xmin.m, ymax.m, z], [-gap, 0, 0])
          dims += 2
          rooms.each do |room|
            label = (room["label"] || room["name"] || "Ruang").to_s
            x, y = room["at"]
            west = reach(model, x, y, base_z, Math::PI)
            east = reach(model, x, y, base_z, 0.0)
            south = reach(model, x, y, base_z, -Math::PI / 2)
            north = reach(model, x, y, base_z, Math::PI / 2)
            unless west && east && south && north
              warnings << "#{label}: no wall found on every side of #{room["at"].inspect}, not dimensioned"
              next
            end
            # Dimension lines sit a third of the way into the room so the two
            # of them and the room name do not land on top of each other.
            y_line = y.to_f - south + (south + north) / 3.0
            x_line = x.to_f - west + (west + east) / 3.0
            ents.add_dimension_linear([(x - west).m, y_line.m, z], [(x + east).m, y_line.m, z], [0, 0.01.m, 0])
            ents.add_dimension_linear([x_line.m, (y - south).m, z], [x_line.m, (y + north).m, z], [0.01.m, 0, 0])
            dims += 2
            cx = x.to_f - west + (west + east) * 0.62
            cy = y.to_f - south + (south + north) * 0.68
            ents.add_text(label, [cx.m, cy.m, z])
          end
        end

        notes.layer = annotation
        prefix = Standards::TABLE['anotasi'][0]
        model.layers.each { |l| l.visible = (l == annotation) if l.name.start_with?(prefix) }
        plane = model.entities.add_section_plane([Geom::Point3d.new(0, 0, z), Geom::Vector3d.new(0, 0, -1)])
        plane.name = name
        plane.layer = annotation
        plane.activate
        model.rendering_options["DisplaySectionPlanes"] = false

        cx = (xmin + xmax) / 2.0
        cy = (ymin + ymax) / 2.0
        camera = Sketchup::Camera.new([cx.m, cy.m, (cut + 30).m], [cx.m, cy.m, 0], Y_AXIS)
        camera.perspective = false
        # Frame the walls that were asked for (plus room for the outside
        # dimensions), not the whole model: other buildings must not push the
        # plan out of the picture. export_scene renders 16:9, so fit both shapes.
        view = model.active_view
        aspect = [view.vpwidth.to_f / view.vpheight, 16.0 / 9].min
        margin = 4.5
        camera.height = [(ymax - ymin) + margin, ((xmax - xmin) + margin) / aspect].max.m
        view.camera = camera
        # The scale figure, the site and sun shadows do not belong on a plan.
        %w[referensi tapak].each do |kind|
          layer = model.layers[Standards::TABLE[kind][0]]
          layer.visible = false if layer
        end
        model.shadow_info['DisplayShadows'] = false
        page = model.pages.add(name)

        # Dimensions and the cut belong to the plan scene only.
        model.pages.each { |p| p.set_visibility(annotation, false) unless p == page }
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end

      summary = "Plan view '#{name}' created: scene '#{name}' (top view, parallel projection, cut #{(cut - base_z).round(2)} m " \
                "above the floor) with #{dims} dimensions on tag '#{Standards::TABLE['anotasi'][0]} #{name}'. " \
                "Outside size #{format('%.3f', xmax - xmin)} x #{format('%.3f', ymax - ymin)} m. " \
                "Scene '3D' returns to the 3D view. Look at it with export_scene(format='png')."
      summary += " Warnings: " + warnings.join("; ") unless warnings.empty?
      summary
    end
  end

  def self.plan_view(spec)
    Plan.build(spec)
  end

  # Checks stairs and furniture against doors and walls, so that something
  # placed from guessed coordinates is caught before the user sees it.
  # See docs/WORKFLOW.md.
  module Placement
    PLACED_KINDS = %w[tangga furnitur].freeze
    DOOR_NAME = /\APintu /.freeze
    # Above this many faces an element is tested by its bounding box only.
    FACE_LIMIT = 4000

    def self.inner(entity)
      entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
    end

    def self.local_bounds(entity)
      entity.is_a?(Sketchup::Group) ? entity.local_bounds : entity.definition.bounds
    end

    # [[xmin, ymin, zmin], [xmax, ymax, zmax]] in inches.
    def self.box(points)
      xs = points.map { |p| p.x.to_f }
      ys = points.map { |p| p.y.to_f }
      zs = points.map { |p| p.z.to_f }
      [[xs.min, ys.min, zs.min], [xs.max, ys.max, zs.max]]
    end

    def self.corners(bounds, tr = nil)
      (0..7).map { |i| tr ? bounds.corner(i).transform(tr) : bounds.corner(i) }
    end

    def self.touch?(a, b)
      (0..2).all? { |i| a[0][i] <= b[1][i] && a[1][i] >= b[0][i] }
    end

    def self.shrink(b, by)
      [b[0].map { |v| v + by }, b[1].map { |v| v - by }]
    end

    # World-space triangles of every face in the element, nested groups included.
    def self.faces(entities, tr, out)
      entities.each do |e|
        return out if out.length > FACE_LIMIT
        if e.is_a?(Sketchup::Face)
          # Triangles, not the face outline: a stair stringer is one large
          # L-shaped face, and its bounding box would include the void under it.
          mesh = e.mesh(0)
          mesh.polygons.each { |poly| out << poly.map { |i| mesh.point_at(i.abs).transform(tr) } }
        elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          faces(inner(e), tr * e.transformation, out)
        end
      end
      out
    end

    def self.collect(model, building, tags)
      placed = []
      doors = []
      walls = []
      walk = lambda do |entities, tr, names|
        entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if e.hidden? || !e.layer.visible?
          here = names + [e.name.to_s]
          wanted = building.nil? || here.include?(building.to_s)
          label = here.reject(&:empty?).join(' > ')
          full = tr * e.transformation
          if tags.include?(e.layer.name)
            next unless wanted
            parts = faces(inner(e), full, [])
            world = box(corners(e.bounds, tr))
            parts = [corners(e.bounds, tr)] if parts.empty? || parts.length > FACE_LIMIT
            placed << { label: label, box: world, parts: parts }
          elsif e.layer.name == Verify::WALL_TAG
            next unless wanted
            walls << { label: label, box: box(corners(e.bounds, tr)), to_local: full.inverse,
                       zone: box(corners(local_bounds(e))) }
          elsif e.name.to_s =~ DOOR_NAME
            doors << door(e, label, tr, full) if wanted
          else
            walk.call(inner(e), full, here)
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, [])
      [placed, doors, walls]
    end

    # A door unit as two zones in the unit's own axes: the clear passage either
    # side of the frame, and the floor area the open leaf sweeps over.
    def self.door(unit, label, tr, full)
      children = inner(unit).select { |c| c.is_a?(Sketchup::Group) || c.is_a?(Sketchup::ComponentInstance) }
      frame = children.find { |c| c.name == 'Kusen' }
      swing = children.find { |c| c.name == 'Ayun' }
      base = box(corners((frame || unit).bounds)) if frame
      base ||= box(corners(local_bounds(unit)))
      { label: label, box: box(corners(unit.bounds, tr)), to_local: full.inverse, frame: !frame.nil?,
        base: base, top: base[1][2], swing: swing ? box(corners(swing.bounds)) : nil }
    end

    def self.passage(door, clearance)
      lo = door[:base][0].dup
      hi = door[:base][1].dup
      return [lo, hi] unless door[:frame]
      # The frame is thin across the wall and wide along it.
      across = (hi[0] - lo[0]) < (hi[1] - lo[1]) ? 0 : 1
      lo[across] -= clearance
      hi[across] += clearance
      [lo, hi]
    end

    def self.where(point)
      format('[%.2f, %.2f, %.2f] m', point.x.to_f.to_m, point.y.to_f.to_m, point.z.to_f.to_m)
    end

    # Triangle against axis-aligned box (separating axes, Akenine-Moller).
    def self.triangle_in_box?(pts, zone)
      c = (0..2).map { |i| (zone[0][i] + zone[1][i]) / 2.0 }
      h = (0..2).map { |i| (zone[1][i] - zone[0][i]) / 2.0 }
      v = pts.map { |p| [p.x.to_f - c[0], p.y.to_f - c[1], p.z.to_f - c[2]] }
      e = [0, 1, 2].map { |i| (0..2).map { |k| v[(i + 1) % 3][k] - v[i][k] } }
      cross = lambda { |a, b| [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
      dot = lambda { |a, b| a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
      n = cross.call(e[0], e[1])
      return false if dot.call(n, v[0]).abs > (0..2).inject(0.0) { |sum, k| sum + h[k] * n[k].abs }
      unit = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
      unit.each do |u|
        e.each do |edge|
          a = cross.call(u, edge)
          ps = v.map { |q| dot.call(a, q) }
          r = (0..2).inject(0.0) { |sum, k| sum + h[k] * a[k].abs }
          return false if ps.min > r || ps.max < -r
        end
      end
      true
    end

    # World point where the element enters zone (given in the axes that
    # to_local maps world points into), or nil.
    def self.hit(item, to_local, zone)
      item[:parts].each do |pts|
        local = pts.map { |p| p.transform(to_local) }
        b = box(local)
        next unless touch?(b, zone)
        next if local.length == 3 && !triangle_in_box?(local, zone)
        mid = (0..2).map { |i| ([b[0][i], zone[0][i]].max + [b[1][i], zone[1][i]].min) / 2.0 }
        return Geom::Point3d.new(*mid).transform(to_local.inverse)
      end
      nil
    end

    def self.report(opts = {})
      model = Sketchup.active_model
      return "PLACEMENT FAILED. No model is open." unless model
      opts ||= {}
      building = opts['building']
      clearance = (opts['clearance'] || 0.6).to_f.m
      tol = (opts['tolerance'] || 0.01).to_f.m
      kinds = opts['kinds'] || PLACED_KINDS
      tags = kinds.map { |k| Standards.row(k)[0] }
      placed, doors, walls = collect(model, building, tags)
      reach = clearance + tol
      problems = []
      notes = []

      placed.each do |item|
        grown = [item[:box][0].map { |v| v - reach }, item[:box][1].map { |v| v + reach }]
        doors.each do |d|
          next unless touch?(grown, d[:box])
          found = hit(item, d[:to_local], shrink(passage(d, clearance), tol))
          if found
            problems << "MENGHALANGI PINTU  #{item[:label]} is inside the #{format('%.2f', clearance.to_m)} m clear passage of #{d[:label]} at #{where(found)}"
            next
          end
          next unless d[:swing]
          sweep = [d[:swing][0].dup, d[:swing][1].dup]
          sweep[1][2] = d[:top]
          found = hit(item, d[:to_local], shrink(sweep, tol))
          problems << "DI AYUNAN PINTU    #{item[:label]} is where the leaf of #{d[:label]} swings, at #{where(found)}" if found
        end
        walls.each do |w|
          next unless touch?(item[:box], w[:box])
          found = hit(item, w[:to_local], shrink(w[:zone], tol))
          problems << "MENEMBUS DINDING   #{item[:label]} goes into wall #{w[:label]} at #{where(found)}" if found
        end
      end
      placed.combination(2) do |a, b|
        next unless touch?(shrink(a[:box], tol), shrink(b[:box], tol))
        notes << "PERIKSA            #{a[:label]} and #{b[:label]} share space (fine for a chair under a table, wrong for two beds)"
      end

      # Findings the user has accepted (a closet door under the stairs needs
      # no clear passage on the closet side) are listed but do not fail the check.
      accepted = (opts['accept'] || []).map(&:to_s)
      waived, problems = problems.partition { |line| accepted.any? { |a| line.include?(a) } }
      notes = waived.map { |line| "DITERIMA           #{line.sub(/\A[A-Z ]+?\s{2,}/, '')}" } + notes

      head = "#{placed.length} elements (#{kinds.join(', ')}) checked against #{doors.length} doors and #{walls.length} walls, " \
             "door clearance #{format('%.2f', clearance.to_m)} m."
      lines = problems.first(40) + notes.first(20)
      if problems.empty?
        "PLACEMENT OK. #{head}" + (lines.empty? ? '' : "\n" + lines.join("\n"))
      else
        "PLACEMENT CONFLICT. #{head} #{problems.length} problem(s):\n" + lines.join("\n")
      end
    end
  end

  def self.check_placement(opts = {})
    Placement.report(opts)
  end

  # Exports every scene to one folder in a single step, and remembers the
  # state of the model so that pictures taken before a later change are
  # reported as stale. See docs/WORKFLOW.md.
  module Views
    MANIFEST = 'views.json'.freeze

    class Watch < Sketchup::ModelObserver
      attr_reader :count

      def initialize
        @count = 0
      end

      def onTransactionCommit(_model)
        @count += 1
      end

      def onTransactionUndo(_model)
        @count += 1
      end

      def onTransactionRedo(_model)
        @count += 1
      end
    end

    @state = nil

    def self.state_for(model)
      return @state if @state && @state[:model] == model
      watch = Watch.new
      model.add_observer(watch)
      @state = { model: model, watch: watch, at: nil, time: nil, folder: nil, files: [] }
    end

    def self.default_folder(model)
      if model.path.to_s.empty?
        base = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, 'sketchup_exports')
        File.join(base, "views_#{Time.now.strftime('%Y%m%d_%H%M%S')}")
      else
        File.join(File.dirname(model.path), "#{File.basename(model.path, '.*')}-gambar")
      end
    end

    def self.status
      model = Sketchup.active_model
      return "VIEWS FAILED. No model is open." unless model
      state = state_for(model)
      return "VIEWS UNKNOWN. export_views has not run for this model in this SketchUp session; run it before showing pictures." unless state[:at]
      changes = state[:watch].count - state[:at]
      where = "#{state[:files].length} pictures in #{state[:folder]} (exported #{state[:time].strftime('%H:%M:%S')})"
      if changes == 0
        "VIEWS CURRENT. #{where} match the model."
      else
        "VIEWS STALE. #{changes} change(s) to the model since the #{where}. Run export_views again before showing them."
      end
    end

    def self.export(opts = {})
      model = Sketchup.active_model
      raise "No model is open in SketchUp" unless model
      opts ||= {}
      return status if opts['check_only']
      state = state_for(model)
      pages = model.pages.to_a
      wanted = opts['scenes']
      if wanted && !wanted.empty?
        missing = wanted - pages.map(&:name)
        raise "No scene named #{missing.join(', ')}. Scenes: #{pages.map(&:name).join(', ')}" unless missing.empty?
        pages = pages.select { |p| wanted.include?(p.name) }
      end
      raise "The model has no scenes. Make them first: add_plan_view, or set the camera and call model.pages.add('Depan')." if pages.empty?

      folder = (opts['folder'] || default_folder(model)).to_s
      FileUtils.mkdir_p(folder)
      width = (opts['width'] || 1920).to_i
      height = (opts['height'] || 1080).to_i
      manifest = File.join(folder, MANIFEST)
      earlier = File.exist?(manifest) ? (JSON.parse(File.read(manifest))['files'] rescue []) : []

      # Scenes switch at once; an animated transition would be caught half way.
      model.options['PageOptions']['ShowTransition'] = false
      view = model.active_view
      back = model.pages.selected_page
      files = []
      all = model.pages.to_a
      pages.each do |page|
        model.pages.selected_page = page
        if page.use_camera?
          c = page.camera
          camera = Sketchup::Camera.new(c.eye, c.target, c.up, c.perspective?)
          c.perspective? ? camera.fov = c.fov : camera.height = c.height
          view.camera = camera
        end
        name = format('%02d-%s.png', all.index(page) + 1, page.name.gsub(/[\\\/:*?"<>|]/, '-'))
        # Opaque: in a transparent PNG everything not covered by geometry shows black.
        # A drawing (plan, elevation: parallel projection) goes on white paper.
        # Sky and ground belong to the style, which all scenes share, so a
        # scene cannot switch them off for itself; and in parallel projection
        # SketchUp paints them as flat bands across the picture.
        ro = model.rendering_options
        paper = nil
        unless view.camera.perspective?
          paper = %w[DrawHorizon DrawGround BackgroundColor].map { |k| [k, ro[k]] }
          ro['DrawHorizon'] = false
          ro['DrawGround'] = false
          ro['BackgroundColor'] = Sketchup::Color.new(255, 255, 255)
        end
        begin
          ok = view.write_image(filename: File.join(folder, name), width: width, height: height,
                                antialias: true, transparent: false)
        ensure
          paper.each { |k, v| ro[k] = v } if paper
        end
        raise "SketchUp could not write #{name}" unless ok
        files << name
      end
      model.pages.selected_page = back if back

      # Pictures this tool wrote earlier for scenes that no longer exist would
      # otherwise sit in the folder looking current.
      removed = []
      if wanted.nil? || wanted.empty?
        (earlier - files).each do |old|
          path = File.join(folder, old)
          next unless old =~ /\A\d\d-.*\.png\z/ && File.exist?(path)
          File.delete(path)
          removed << old
        end
        kept = files
      else
        kept = (earlier | files)
      end
      File.write(manifest, JSON.pretty_generate('model' => model.path.to_s, 'exported' => Time.now.strftime('%Y-%m-%d %H:%M:%S'), 'files' => kept))

      state[:at] = state[:watch].count
      state[:time] = Time.now
      state[:folder] = folder
      state[:files] = kept
      summary = "VIEWS EXPORTED. #{files.length} scene(s), #{width} x #{height}, to #{folder}:\n" + files.join("\n")
      summary += "\nRemoved pictures of scenes that no longer exist: #{removed.join(', ')}" unless removed.empty?
      summary
    end
  end

  def self.export_views(opts = {})
    Views.export(opts)
  end

  def self.views_status
    Views.status
  end
  # Roofs and the details that make a model read as a building: cladding
  # boards, corner boards, window trim and shutters, posts, stairs, furniture.
  # Everything is given in metres and follows the house rules. See docs/DETAIL.md.
  module Detail
    WHITE = [245, 245, 240].freeze
    # What counts as "a building is in the way" when looking for outside faces.
    BLOCKING = %w[dinding pintu jendela].map { |k| Standards::TABLE[k][0] }.freeze

    def self.operation(name)
      model = Sketchup.active_model
      raise "No model is open in SketchUp" unless model
      model.start_operation("MCP: #{name}", true)
      begin
        result = yield model
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # An untagged container group inside parent, created on first use.
    def self.child(parent, name)
      found = parent.entities.grep(Sketchup::Group).find { |g| g.name == name.to_s }
      return found if found
      model = Sketchup.active_model
      previous = model.active_layer
      model.active_layer = model.layers[0]
      begin
        group = parent.entities.add_group
        group.name = name.to_s
        group
      ensure
        model.active_layer = previous
      end
    end

    def self.home(spec, default_group = nil)
      building = Standards.container((spec['building'] || 'Bangunan').to_s)
      name = spec.key?('group') ? spec['group'] : default_group
      name ? child(building, name) : building
    end

    def self.pt(x, y, z)
      Geom::Point3d.new(x.to_f.m, y.to_f.m, z.to_f.m)
    end

    def self.face(ents, pts)
      clean = []
      pts.each { |q| clean << q unless clean.last && clean.last.distance(q) < 0.001 }
      clean.pop while clean.length > 1 && clean.first.distance(clean.last) < 0.001
      return nil if clean.length < 3
      ents.add_face(clean)
    end

    # Points of a ring that are real corners (collinear ones dropped).
    def self.corners(ring)
      n = ring.length
      kept = (0...n).select do |i|
        a = ring[i] - ring[i - 1]
        b = ring[(i + 1) % n] - ring[i]
        a.length < 0.001 || b.length < 0.001 ? false : (a * b).length > 0.0001
      end
      kept.map { |i| ring[i] }
    end

    # Closed skin over a stack of rings with the same number of points.
    def self.skin(ents, rings)
      face(ents, corners(rings.first))
      face(ents, corners(rings.last))
      rings.each_cons(2) do |low, high|
        n = low.length
        n.times do |i|
          j = (i + 1) % n
          face(ents, [low[i], low[j], high[j], high[i]])
        end
      end
    end

    def self.loft(ents, bottom, top)
      face(ents, bottom)
      face(ents, top)
      n = bottom.length
      n.times do |i|
        j = (i + 1) % n
        face(ents, [bottom[i], bottom[j], top[j], top[i]])
      end
    end

    # Upright prism over a plan polygon, metres.
    def self.prism(ents, plan, z0, z1)
      loft(ents, plan.map { |x, y| pt(x, y, z0) }, plan.map { |x, y| pt(x, y, z1) })
    end

    def self.box(ents, x0, x1, y0, y1, z0, z1)
      prism(ents, [[x0, y0], [x1, y0], [x1, y1], [x0, y1]], z0, z1)
    end

    def self.paint(faces, material)
      faces.each do |f|
        f.material = material
        f.back_material = material
      end
    end

    def self.pitch(spec)
      return Math.tan(spec['pitch_deg'].to_f.degrees) if spec['pitch_deg']
      v = spec['pitch']
      return 0.5 if v.nil?
      if v.is_a?(String) && v.include?(':')
        rise, run = v.split(':').map(&:to_f)
        return rise / run
      end
      v.to_f
    end

    # Lines running down the slope of a planar roof face, `spacing` apart.
    # poly: Point3d corners; down: [dx, dy], the downhill direction on plan.
    def self.seams(ents, poly, down, spacing)
      return 0 if spacing <= 0
      ex = -down[1]
      ey = down[0]
      us = poly.map { |q| q.x.to_f * ex + q.y.to_f * ey }
      umin = us.min
      umax = us.max
      n = ((umax - umin) / spacing).floor
      return 0 if n < 1
      start = umin + ((umax - umin) - n * spacing) / 2.0
      count = 0
      (0..n).each do |k|
        u = start + k * spacing
        next if u - umin < 0.5 || umax - u < 0.5
        hits = []
        poly.each_with_index do |q, i|
          j = (i + 1) % poly.length
          next if (us[i] > u) == (us[j] > u)
          f = (u - us[i]) / (us[j] - us[i])
          hits << Geom::Point3d.linear_combination(1 - f, q, f, poly[j])
        end
        next unless hits.length == 2 && hits[0].distance(hits[1]) > 0.5
        ents.add_line(hits[0], hits[1])
        count += 1
      end
      count
    end

    # ---------------------------------------------------------------- roof

    def self.roof(spec)
      type = (spec['type'] || 'gable').to_s
      raise "Unknown roof type #{type.inspect}. Use gable, hip, shed or flat" unless %w[gable hip shed flat].include?(type)
      raise 'A roof needs "from" and "to": two opposite corners of the wall outline, in metres' unless spec['from'] && spec['to']
      fx, fy = spec['from']
      tx, ty = spec['to']
      lo = [[fx, tx].min.to_f, [fy, ty].min.to_f]
      hi = [[fx, tx].max.to_f, [fy, ty].max.to_f]
      raise 'Roof outline has no area' if hi[0] - lo[0] < 0.05 || hi[1] - lo[1] < 0.05
      p = type == 'flat' ? 0.0 : pitch(spec)
      oh = (spec['overhang'] || 0.3).to_f
      rake = (spec['rake'] || oh).to_f
      t = (spec['thickness'] || 0.15).to_f
      tv = t * Math.sqrt(1 + p * p)
      spacing = (spec['seams'] || 0).to_f.m
      base = (spec['base_z'] || 0).to_f
      name = (spec['name'] || "Atap #{type.capitalize}").to_s
      tops = []
      info = nil
      walls = 0
      lines = 0

      operation(name) do
        parent = home(spec, 'Atap')
        parent.entities.grep(Sketchup::Group).select { |g| g.name == name || g.name =~ /\A#{Regexp.escape(name)} Ampig \d\z/ }.each(&:erase!)
        roof = Standards.element(name, :atap, parent, spec['material'], spec['color']) do |ents|
          case type
          when 'gable'
            a = (spec['ridge'] || ((hi[0] - lo[0]) >= (hi[1] - lo[1]) ? 'x' : 'y')).to_s == 'x' ? 0 : 1
            c = 1 - a
            q = lambda { |av, cv, z| a == 0 ? pt(av, cv, z) : pt(cv, av, z) }
            half = (hi[c] - lo[c]) / 2.0
            mid = (hi[c] + lo[c]) / 2.0
            w = half + oh
            ze = base - oh * p
            zr = base + half * p
            profile = [[mid - w, ze], [mid, zr], [mid + w, ze], [mid + w, ze + tv], [mid, zr + tv], [mid - w, ze + tv]]
            a0 = lo[a] - rake
            a1 = hi[a] + rake
            loft(ents, profile.map { |cv, z| q.call(a0, cv, z) }, profile.map { |cv, z| q.call(a1, cv, z) })
            up = a == 0 ? [0, 1] : [1, 0]
            tops << [[q.call(a0, mid + w, ze + tv), q.call(a1, mid + w, ze + tv), q.call(a1, mid, zr + tv), q.call(a0, mid, zr + tv)], up]
            tops << [[q.call(a0, mid - w, ze + tv), q.call(a1, mid - w, ze + tv), q.call(a1, mid, zr + tv), q.call(a0, mid, zr + tv)], up.map { |v| -v }]
            info = { ridge: zr + tv, eave: ze, size: [a1 - a0, 2 * w], axis: a, half: half, mid: mid, zr: zr }
          when 'hip'
            a = (hi[0] - lo[0]) >= (hi[1] - lo[1]) ? 0 : 1
            c = 1 - a
            q = lambda { |av, cv, z| a == 0 ? pt(av, cv, z) : pt(cv, av, z) }
            a0 = lo[a] - oh
            a1 = hi[a] + oh
            c0 = lo[c] - oh
            c1 = hi[c] + oh
            hs = (c1 - c0) / 2.0
            mid = (c0 + c1) / 2.0
            ze = base - oh * p
            zr = ze + tv + hs * p
            low = [q.call(a0, c0, ze), q.call(a1, c0, ze), q.call(a1, c1, ze), q.call(a0, c1, ze)]
            rim = [q.call(a0, c0, ze + tv), q.call(a1, c0, ze + tv), q.call(a1, c1, ze + tv), q.call(a0, c1, ze + tv)]
            r1 = q.call(a0 + hs, mid, zr)
            r2 = q.call(a1 - hs, mid, zr)
            face(ents, low)
            4.times { |i| face(ents, [low[i], low[(i + 1) % 4], rim[(i + 1) % 4], rim[i]]) }
            along = a == 0 ? [1, 0] : [0, 1]
            across = a == 0 ? [0, 1] : [1, 0]
            tops << [[rim[0], rim[1], r2, r1], across.map { |v| -v }]
            tops << [[rim[2], rim[3], r1, r2], across]
            tops << [[rim[3], rim[0], r1], along.map { |v| -v }]
            tops << [[rim[1], rim[2], r2], along]
            tops.each { |poly, _| face(ents, poly) }
            info = { ridge: zr, eave: ze, size: [a1 - a0, c1 - c0] }
          when 'shed'
            side = (spec['high_side'] || 'north').to_s
            c, s = { 'north' => [1, 1], 'south' => [1, -1], 'east' => [0, 1], 'west' => [0, -1] }[side] ||
                   raise("high_side must be north, south, east or west, not #{side.inspect}")
            a = 1 - c
            q = lambda { |av, cv, z| a == 0 ? pt(av, cv, z) : pt(cv, av, z) }
            depth = hi[c] - lo[c]
            ch = s > 0 ? hi[c] : lo[c]
            cl = s > 0 ? lo[c] : hi[c]
            zh = spec['top_z'] ? spec['top_z'].to_f : base + depth * p
            miter = spec['miter'] || {}
            ms = miter['start'] ? true : false
            me = miter['end'] ? true : false
            ohh = ms || me ? 0.0 : (spec['overhang_high'] || 0).to_f
            c_low = cl - s * oh
            c_high = ch + s * ohh
            plan = [[lo[a] - (ms ? oh : rake), c_low], [hi[a] + (me ? oh : rake), c_low],
                    [me ? hi[a] - depth : hi[a] + rake, c_high], [ms ? lo[a] + depth : lo[a] - rake, c_high]]
            under = lambda { |cv| zh - s * (ch - cv) * p }
            bottom = plan.map { |av, cv| q.call(av, cv, under.call(cv)) }
            top = plan.map { |av, cv| q.call(av, cv, under.call(cv) + tv) }
            loft(ents, bottom, top)
            tops << [top, a == 0 ? [0, -s] : [-s, 0]]
            info = { ridge: under.call(c_high) + tv, eave: under.call(c_low), size: [plan[1][0] - plan[0][0], (c_high - c_low).abs] }
          else
            box(ents, lo[0] - oh, hi[0] + oh, lo[1] - oh, hi[1] + oh, base, base + t)
            info = { ridge: base + t, eave: base, size: [hi[0] - lo[0] + 2 * oh, hi[1] - lo[1] + 2 * oh] }
          end
          tops.each { |poly, down| lines += seams(ents, poly, down, spacing) }
          unless spec.key?('fascia') && !spec['fascia']
            rgb = spec['fascia'].is_a?(Array) ? spec['fascia'] : WHITE
            paint(ents.grep(Sketchup::Face).select { |f| f.normal.z.abs < 0.01 }, Standards.material(:atap, 'Atap - Lisplang Putih', rgb))
          end
        end

        gw = spec['gable_walls']
        if type == 'gable' && gw
          gw = {} unless gw.is_a?(Hash)
          tw = (gw['thickness'] || 0.15).to_f
          a = info[:axis]
          c = 1 - a
          q = lambda { |av, cv, z| a == 0 ? pt(av, cv, z) : pt(cv, av, z) }
          [[lo[a], lo[a] + tw], [hi[a], hi[a] - tw]].each_with_index do |(out_a, in_a), i|
            Standards.element("#{name} Ampig #{i + 1}", :dinding, parent, gw['material'], gw['color']) do |ents|
              tri = [[lo[c], base], [hi[c], base], [info[:mid], info[:zr]]]
              loft(ents, tri.map { |cv, z| q.call(out_a, cv, z) }, tri.map { |cv, z| q.call(in_a, cv, z) })
            end
            walls += 1
          end
        end
        summary = "Roof '#{name}' (#{type}) built in '#{parent.name}': top of ridge at +#{format('%.3f', info[:ridge])} m, " \
                  "underside of eave at +#{format('%.3f', info[:eave])} m, #{format('%.2f', info[:size][0])} x #{format('%.2f', info[:size][1])} m on plan"
        summary += ", pitch #{format('%.3f', p)} (#{format('%.1f', Math.atan(p).radians)} deg)" unless type == 'flat'
        summary += ", #{lines} seam lines" if lines > 0
        summary += ", #{walls} gable walls" if walls > 0
        summary + ". Group entityID #{roof.entityID}. Look at it with export_scene, then SU_MCP.audit_model."
      end
    end

    # ------------------------------------------------------- outside faces

    def self.blocked?(model, origin, dir)
      point = origin
      8.times do
        hit = model.raytest([point, dir], true)
        return false unless hit
        return false if origin.distance(hit[0]) > 30.m
        return true if hit[1].any? { |e| e.respond_to?(:layer) && e.layer && BLOCKING.include?(e.layer.name) }
        point = hit[0].offset(dir, 0.05)
      end
      true
    end

    # How many of `count` horizontal directions, fanned over `spread` degrees
    # around `angle`, are free of buildings. Outside a wall most are; inside a
    # room hardly any, even with a door standing open.
    def self.escapes(model, origin, angle, spread = 168.0, count = 15)
      (0...count).count do |i|
        a = angle + (spread * (i.to_f / (count - 1) - 0.5)).degrees
        !blocked?(model, origin, Geom::Vector3d.new(Math.cos(a), Math.sin(a), 0))
      end
    end
    OUTSIDE = 6

    def self.each_group(model, building, floor, tr = Geom::Transformation.new, entities = nil, names = [], &block)
      (entities || model.entities).each do |e|
        next unless e.is_a?(Sketchup::Group)
        here = names + [e.name.to_s]
        full = tr * e.transformation
        wanted = (building.nil? || here.include?(building.to_s)) && (floor.nil? || here.include?(floor.to_s))
        descend = block.call(e, full, tr, wanted)
        each_group(model, building, floor, full, e.entities, here, &block) if descend
      end
    end

    def self.crossings(ring, value, axis)
      out = []
      ring.each_with_index do |a, i|
        b = ring[(i + 1) % ring.length]
        next if (a[axis] > value) == (b[axis] > value)
        f = (value - a[axis]) / (b[axis] - a[axis])
        out << a[1 - axis] + f * (b[1 - axis] - a[1 - axis])
      end
      out.sort
    end

    def self.subtract(spans, holes)
      holes.each do |h0, h1|
        spans = spans.flat_map do |s0, s1|
          next [[s0, s1]] if h1 <= s0 || h0 >= s1
          parts = []
          parts << [s0, h0] if h0 > s0
          parts << [h1, s1] if h1 < s1
          parts
        end
      end
      spans
    end

    def self.intersect(spans, runs)
      spans.flat_map { |s0, s1| runs.map { |r0, r1| [[s0, r0].max, [s1, r1].min] } }.select { |a, b| b - a > 0.5 }
    end

    # ---------------------------------------------------------------- siding

    def self.siding(spec)
      style = (spec['style'] || 'clapboard').to_s
      raise "Unknown siding style #{style.inspect}. Use clapboard or batten" unless %w[clapboard batten].include?(style)
      spacing = (spec['spacing'] || (style == 'batten' ? 0.4 : 0.125)).to_f.m
      raise 'spacing must be at least 0.02 m' if spacing < 0.02.m
      cb = spec.key?('corner_boards') ? spec['corner_boards'] : 0.09
      cb = 0.09 if cb == true
      cb = cb ? cb.to_f : 0.0
      only = spec['only']
      skip = spec['skip'] || []
      force = spec['force'] || []
      building = spec['building']
      floor = spec['floor']
      cell = 0.25.m
      lines = 0
      clad = []
      inside = []
      ends = []
      boards = 0

      operation('papan dinding') do |model|
        targets = []
        each_group(model, building, floor) do |g, full, _tr, wanted|
          if g.layer.name == Verify::WALL_TAG
            id = g.name.to_s.sub(/\ADinding /, '')
            targets << [g, full, id] if wanted && (only.nil? || only.include?(id)) && !skip.include?(id)
            false
          else
            true
          end
        end
        raise "No walls found (tag #{Verify::WALL_TAG})#{building ? " in #{building}" : ''}; build the floor plan first" if targets.empty?

        targets.each do |g, tr, id|
          inv = tr.inverse
          upright = g.entities.grep(Sketchup::Face).select { |f| f.normal.transform(tr).z.abs < 0.01 }
          next if upright.empty?
          n0 = upright.max_by(&:area).normal.transform(tr).normalize
          world = g.entities.grep(Sketchup::Edge).flat_map { |e| e.vertices }.uniq.map { |v| v.position.transform(tr) }
          zbase = world.map { |q| q.z.to_f }.min
          ztop = world.map { |q| q.z.to_f }.max
          ztest = zbase + [1.0.m, (ztop - zbase) / 2.0].min
          middle = Geom::Point3d.new(*(0..2).map { |i| world.inject(0.0) { |sum, q| sum + q.to_a[i].to_f } / world.length })
          got = false
          # Lines already there (an earlier run) are not drawn or counted again.
          drawn = g.entities.grep(Sketchup::Edge).map { |e| [e.start.position, e.end.position] }
          draw = lambda do |a, b|
            mid = Geom::Point3d.linear_combination(0.5, a, 0.5, b)
            dir = b - a
            unless drawn.any? { |s, t| (mid.distance(s) + mid.distance(t) - s.distance(t)).abs < 0.01 && (t - s).parallel?(dir) }
              g.entities.add_line(a, b)
              drawn << [a, b]
              lines += 1
            end
          end
          upright.select { |f| f.normal.transform(tr).normalize.dot(n0).abs > 0.99 }.each do |f|
            n = f.normal.transform(tr).normalize
            # Outward is away from the body of the wall, whichever way the face is wound.
            n = n.reverse if (f.bounds.center.transform(tr) - middle).dot(n) < 0
            tan = Geom::Vector3d.new(-n.y, n.x, 0)
            u_of = lambda { |q| q.x.to_f * tan.x + q.y.to_f * tan.y }
            anchor = world.map { |q| u_of.call(q) }.min
            outer = f.outer_loop.vertices.map { |v| v.position.transform(tr) }
            p0 = outer[0]
            u0 = u_of.call(p0)
            at = lambda { |u, z| Geom::Point3d.new(p0.x + tan.x * (u - u0), p0.y + tan.y * (u - u0), z) }
            ring = outer.map { |q| [u_of.call(q), q.z.to_f] }
            holes = (f.loops - [f.outer_loop]).map { |l| l.vertices.map { |v| q = v.position.transform(tr); [u_of.call(q), q.z.to_f] } }
            fu0 = ring.map(&:first).min
            fu1 = ring.map(&:first).max
            fz0 = ring.map(&:last).min
            fz1 = ring.map(&:last).max
            next if fu1 - fu0 < 4

            # Which stretches of this face look out on open air.
            angle = Math.atan2(n.y, n.x)
            runs = []
            count = ((fu1 - fu0) / cell).ceil
            width = (fu1 - fu0) / count
            count.times do |i|
              ua = fu0 + i * width
              origin = at.call(ua + width / 2.0, ztest).offset(n, 0.1.m)
              next unless force.include?(id) || escapes(model, origin, angle) >= OUTSIDE
              if runs.last && (runs.last[1] - ua).abs < 0.01
                runs.last[1] = ua + width
              else
                runs << [ua, ua + width]
              end
            end
            next if runs.empty?
            got = true
            runs.each do |ra, rb|
              ends << { pt: at.call(ra, 0), t: tan, n: n, z0: zbase, z1: ztop, wall: id } if (ra - fu0).abs < 1
              ends << { pt: at.call(rb, 0), t: tan.reverse, n: n, z0: zbase, z1: ztop, wall: id } if (rb - fu1).abs < 1
            end

            if style == 'clapboard'
              k = 1
              while (z = zbase + k * spacing) < fz1 - 0.2
                k += 1
                next if z < fz0 + 0.2
                spans = crossings(ring, z, 1).each_slice(2).select { |pair| pair.length == 2 }
                spans = subtract(spans, holes.flat_map { |h| crossings(h, z, 1).each_slice(2).select { |pair| pair.length == 2 } })
                intersect(spans, runs).each do |ua, ub|
                  draw.call(at.call(ua, z).transform(inv), at.call(ub, z).transform(inv))
                end
              end
            else
              k = 0
              while (u = anchor + spacing / 2.0 + k * spacing) < fu1 - 0.2
                k += 1
                next if u < fu0 + 0.2 || runs.none? { |ra, rb| u > ra && u < rb }
                spans = crossings(ring, u, 0).each_slice(2).select { |pair| pair.length == 2 }
                spans = subtract(spans, holes.flat_map { |h| crossings(h, u, 0).each_slice(2).select { |pair| pair.length == 2 } })
                spans.each do |za, zb|
                  next if zb - za < 0.5
                  draw.call(at.call(u, za).transform(inv), at.call(u, zb).transform(inv))
                end
              end
            end
          end
          (got ? clad : inside) << id
        end

        if cb > 0
          trim = child(Standards.container((building || 'Bangunan').to_s), 'Lis')
          prefix = floor ? "Papan Sudut #{floor} " : 'Papan Sudut '
          trim.entities.grep(Sketchup::Group).select { |g| floor ? g.name.start_with?(prefix) : g.name =~ /\APapan Sudut \d+\z/ }.each(&:erase!)
          seen = {}
          e = 0.02.m
          w = cb.m
          ends.combination(2) do |a, b|
            next if a[:wall] == b[:wall] || a[:n].dot(b[:n]).abs > 0.2
            next if a[:pt].distance(b[:pt]) > 0.4.m
            next unless a[:t].dot(b[:n]) < -0.5 && b[:t].dot(a[:n]) < -0.5
            corner = Geom.intersect_line_line([a[:pt], a[:t]], [b[:pt], b[:t]])
            next unless corner
            z0 = [a[:z0], b[:z0]].max
            z1 = [a[:z1], b[:z1]].min
            next if z1 - z0 < 0.3.m
            key = [corner.x.to_f.round, corner.y.to_f.round, z0.round]
            next if seen[key]
            seen[key] = true
            plan = [corner.offset(a[:n], e).offset(b[:n], e), corner.offset(a[:t], w).offset(a[:n], e), corner.offset(a[:t], w),
                    corner, corner.offset(b[:t], w), corner.offset(b[:t], w).offset(b[:n], e)]
            boards += 1
            Standards.element("#{prefix}#{boards}", :struktur, trim, 'Dinding - Lis Putih', WHITE) do |ents|
              loft(ents, plan.map { |q| Geom::Point3d.new(q.x, q.y, z0) }, plan.map { |q| Geom::Point3d.new(q.x, q.y, z1) })
            end
          end
        end

        summary = "Siding (#{style}, every #{format('%.3f', spacing.to_m)} m): #{lines} lines on the outside faces of #{clad.length} walls " \
                  "(#{clad.join(', ')})"
        summary += ", #{boards} corner boards" if cb > 0
        summary += ". No outside face found on: #{inside.join(', ')} (inside walls; use \"force\" if one of them is wrong)" unless inside.empty?
        summary + ". Look at it with export_scene."
      end
    end

    # ------------------------------------------------------------ window trim

    TRIM_NAMES = ['Lis Atas', 'Lis Bawah', 'Shutter Kiri', 'Shutter Kanan'].freeze

    def self.window_trim(spec)
      building = spec['building']
      floor = spec['floor']
      head = spec.key?('head') ? spec['head'] : true
      sill = spec.key?('sill') ? spec['sill'] : true
      shutters = spec.key?('shutters') ? spec['shutters'] : true
      louvre = (spec['louvre'] || 0.035).to_f.m
      shutter_material = (spec['shutter_material'] || 'Jendela - Shutter Hijau').to_s
      shutter_color = spec['shutter_color'] || [38, 62, 48]
      done = []
      warnings = []

      operation('lis jendela') do |model|
        units = []
        each_group(model, building, floor) do |g, full, _tr, wanted|
          if g.name.to_s =~ /\AJendela /
            units << [g, full] if wanted
            false
          else
            g.layer.name != Verify::WALL_TAG
          end
        end
        raise "No window units found (groups named 'Jendela ...' made by build_floor_plan)" if units.empty?

        units.each do |unit, tr|
          unit.entities.grep(Sketchup::Group).select { |g| TRIM_NAMES.include?(g.name) }.each(&:erase!)
          frame = unit.entities.grep(Sketchup::Group).find { |g| g.name == 'Kusen' }
          unless frame
            warnings << "#{unit.name}: no frame (Kusen), skipped"
            next
          end
          b = frame.bounds
          across = b.width < b.height ? 0 : 1
          along = 1 - across
          lo = b.min.to_a.map(&:to_f)
          hi = b.max.to_a.map(&:to_f)
          mid = [(lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0, (lo[2] + hi[2]) / 2.0]
          local = lambda do |a, c, z|
            along == 0 ? Geom::Point3d.new(a, c, z) : Geom::Point3d.new(c, a, z)
          end
          bw = (across == 0 ? Geom::Vector3d.new(1, 0, 0) : Geom::Vector3d.new(0, 1, 0)).transform(tr).normalize
          reach = 0.5.m
          free = [1, -1].map do |side|
            probe = local.call(mid[along], mid[across] + side * reach, mid[2]).transform(tr)
            escapes(model, probe, Math.atan2(side * bw.y, side * bw.x))
          end
          side = free[0] >= free[1] ? 1 : -1
          if free.max < OUTSIDE || (free.min >= OUTSIDE && !spec['force'])
            warnings << "#{unit.name}: cannot tell which side is outside (#{free.min >= OUTSIDE ? 'both sides open' : 'both sides enclosed'}), skipped"
            next
          end

          # Where the wall face is on the outside, found by looking back at the wall beside the window.
          surface = nil
          [1, -1].each do |dir|
            start = local.call(mid[along] + dir * ((hi[along] - lo[along]) / 2.0 + 0.15.m), mid[across] + side * reach, mid[2]).transform(tr)
            hit = model.raytest([start, side > 0 ? bw.reverse : bw], true)
            next unless hit && hit[1].any? { |e| e.respond_to?(:layer) && e.layer.name == Verify::WALL_TAG }
            surface = mid[across] + side * (reach - start.distance(hit[0]))
            break
          end
          surface ||= (side > 0 ? hi[across] : lo[across]) + side * 0.02.m

          slab = lambda do |ents, a0, a1, depth, z0, z1|
            c0, c1 = [surface, surface + side * depth].sort
            ring = [[a0, c0], [a1, c0], [a1, c1], [a0, c1]]
            loft(ents, ring.map { |a, c| local.call(a, c, z0) }, ring.map { |a, c| local.call(a, c, z1) })
          end
          a0 = lo[along]
          a1 = hi[along]
          if head
            Standards.element('Lis Atas', :jendela, unit, 'Jendela - Lis Putih', WHITE) { |ents| slab.call(ents, a0 - 0.04.m, a1 + 0.04.m, 0.03.m, hi[2], hi[2] + 0.10.m) }
          end
          if sill
            Standards.element('Lis Bawah', :jendela, unit, 'Jendela - Lis Putih', WHITE) { |ents| slab.call(ents, a0 - 0.04.m, a1 + 0.04.m, 0.04.m, lo[2] - 0.05.m, lo[2]) }
          end
          if shutters
            ws = (a1 - a0) / 2.0
            th = 0.03.m
            [['Shutter Kiri', a0 - ws, a0], ['Shutter Kanan', a1, a1 + ws]].each do |label, s0, s1|
              Standards.element(label, :jendela, unit, shutter_material, shutter_color) do |ents|
                slab.call(ents, s0, s1, th, lo[2], hi[2])
                z = lo[2] + 0.06.m
                while louvre > 0.01.m && z < hi[2] - 0.06.m
                  ents.add_line(local.call(s0 + 0.03.m, surface + side * th, z), local.call(s1 - 0.03.m, surface + side * th, z))
                  z += louvre
                end
              end
            end
          end
          done << unit.name
        end

        parts = [head ? 'head' : nil, sill ? 'sill' : nil, shutters ? 'shutters' : nil].compact.join(', ')
        summary = "Window trim (#{parts}) added to #{done.length} of #{units.length} windows."
        summary += " Warnings: " + warnings.join('; ') unless warnings.empty?
        summary + " Look at it with export_scene."
      end
    end

    # ----------------------------------------------------------------- posts

    # Turned profile between the square foot and the square head:
    # [fraction of the turned length, radius as a fraction of the post size].
    TURNED = [[0.0, 0.46], [0.04, 0.5], [0.07, 0.36], [0.11, 0.46], [0.3, 0.5], [0.74, 0.3],
              [0.86, 0.33], [0.9, 0.46], [0.94, 0.34], [1.0, 0.44]].freeze
    SEGMENTS = 16

    def self.ring(cx, cy, z, shape, r)
      (0...SEGMENTS).map do |i|
        a = 2 * Math::PI * i / SEGMENTS
        k = shape == :square ? r / [Math.cos(a).abs, Math.sin(a).abs].max : r
        pt(cx + k * Math.cos(a), cy + k * Math.sin(a), z)
      end
    end

    def self.soften(ents)
      ents.grep(Sketchup::Edge).each do |e|
        fs = e.faces
        next unless fs.length == 2
        angle = fs[0].normal.angle_between(fs[1].normal)
        angle = Math::PI - angle if angle > Math::PI / 2
        next unless angle < 30.degrees
        e.soft = true
        e.smooth = true
      end
    end

    def self.posts(spec)
      points = spec['points'] || raise('add_posts needs "points": [[x, y], ...] in metres')
      style = (spec['style'] || 'turned').to_s
      raise "Unknown post style #{style.inspect}. Use turned, square or round" unless %w[turned square round].include?(style)
      size = (spec['size'] || 0.14).to_f
      base = (spec['base_z'] || 0).to_f
      height = (spec['height'] || 2.4).to_f
      label = (spec['name'] || 'Tiang').to_s
      foot = (spec['foot'] || [0.75, height * 0.3].min).to_f
      cap = (spec['cap'] || [0.25, height * 0.12].min).to_f
      profile = spec['profile'] || TURNED
      made = 0

      operation(label) do
        parent = home(spec, 'Teras')
        parent.entities.grep(Sketchup::Group).select { |g| g.name =~ /\A#{Regexp.escape(label)} \d+\z/ }.each(&:erase!)
        points.each_with_index do |(x, y), i|
          Standards.element("#{label} #{i + 1}", :struktur, parent, spec['material'] || 'Struktur - Kayu Putih', spec['color'] || WHITE) do |ents|
            h = size / 2.0
            rings = case style
                    when 'square'
                      [ring(x, y, base, :square, h), ring(x, y, base + height, :square, h)]
                    when 'round'
                      [ring(x, y, base, :round, h), ring(x, y, base + height, :round, h)]
                    else
                      z0 = base + foot
                      z1 = base + height - cap
                      turned = profile.map { |f, r| ring(x, y, z0 + f.to_f * (z1 - z0), :round, r.to_f * size) }
                      [ring(x, y, base, :square, h), ring(x, y, z0, :square, h)] + turned +
                        [ring(x, y, z1, :square, h), ring(x, y, base + height, :square, h)]
                    end
            skin(ents, rings)
            soften(ents)
          end
          made += 1
        end
        "#{made} posts '#{label} 1..#{made}' (#{style}, #{format('%.2f', size)} m, #{format('%.2f', height)} m high from +#{format('%.2f', base)} m) " \
          "built in '#{parent.name}'. Look at them with export_scene."
      end
    end

    # ---------------------------------------------------------------- stairs

    def self.stairs(spec)
      start = spec['start'] || raise('build_stairs needs "start": [x, y], the middle of the first riser, in metres')
      rise = (spec['rise'] || raise('build_stairs needs "rise": the height from floor to floor, in metres')).to_f
      risers = (spec['risers'] || (rise / 0.18).round).to_i
      raise 'A stair needs at least 2 risers' if risers < 2
      r = rise / risers
      width = (spec['width'] || 0.9).to_f
      tread = (spec['tread'] || 0.25).to_f
      base = (spec['base_z'] || 0).to_f
      waist = (spec['waist'] || 0.12).to_f
      label = (spec['name'] || 'Tangga').to_s
      segments = spec['segments'] || [{ 'type' => 'flight', 'treads' => risers - 1 }]
      angle = (spec['direction'] || 90).to_f.degrees
      pos = [start[0].to_f, start[1].to_f]
      dir = [Math.cos(angle), Math.sin(angle)]
      level = 0
      parts = 0
      xs = []
      ys = []
      note = lambda do |pts|
        pts.each do |x, y|
          xs << x
          ys << y
        end
      end

      operation(label) do
        parent = child(home(spec), label)
        parent.entities.grep(Sketchup::Group).each(&:erase!)
        segments.each do |seg|
          type = (seg['type'] || 'flight').to_s
          left = [-dir[1], dir[0]]
          turn = (seg['turn'] || 'none').to_s
          sign = turn == 'right' ? -1 : 1
          parts += 1
          case type
          when 'flight'
            n = (seg['treads'] || 1).to_i
            z0 = base + level * r
            profile = level == 0 ? [[0.0, z0]] : [[0.0, z0 - waist]]
            n.times { |i| profile << [i * tread, z0 + (i + 1) * r] << [(i + 1) * tread, z0 + (i + 1) * r] }
            profile << [n * tread, z0 + n * r - waist]
            profile << [[waist * tread / r, n * tread].min, z0] if level == 0
            side = lambda do |k|
              profile.map { |s, z| pt(pos[0] + dir[0] * s + left[0] * k, pos[1] + dir[1] * s + left[1] * k, z) }
            end
            Standards.element("#{label} #{parts} Lurus", :tangga, parent, spec['material'], spec['color']) do |ents|
              loft(ents, side.call(-width / 2.0), side.call(width / 2.0))
            end
            note.call([-1, 1].flat_map { |k| [0, n * tread].map { |s| [pos[0] + dir[0] * s + left[0] * k * width / 2.0, pos[1] + dir[1] * s + left[1] * k * width / 2.0] } })
            pos = [pos[0] + dir[0] * n * tread, pos[1] + dir[1] * n * tread]
            level += n
          when 'winder', 'landing'
            raise "#{type} needs \"turn\": \"left\" or \"right\"" if turn == 'none' && type == 'winder'
            if turn == 'none'
              length = (seg['length'] || width).to_f
              plan = [-1, 1].map { |k| [pos[0] + left[0] * k * width / 2.0, pos[1] + left[1] * k * width / 2.0] }
              plan += [1, -1].map { |k| [pos[0] + dir[0] * length + left[0] * k * width / 2.0, pos[1] + dir[1] * length + left[1] * k * width / 2.0] }
              top = base + (level + 1) * r
              Standards.element("#{label} #{parts} Bordes", :tangga, parent, spec['material'], spec['color']) { |ents| prism(ents, plan, top - r, top) }
              note.call(plan)
              pos = [pos[0] + dir[0] * length, pos[1] + dir[1] * length]
              level += 1
              next
            end
            inner = [left[0] * sign, left[1] * sign]
            pivot = [pos[0] + inner[0] * width / 2.0, pos[1] + inner[1] * width / 2.0]
            u = [-inner[0], -inner[1]]
            at = lambda { |a, b| [pivot[0] + u[0] * a + dir[0] * b, pivot[1] + u[1] * a + dir[1] * b] }
            steps = type == 'winder' ? (seg['steps'] || 3).to_i : 1
            edge = lambda do |deg|
              a = deg.degrees
              deg <= 45 ? at.call(width, width * Math.tan(a)) : at.call(width / Math.tan(a), width)
            end
            steps.times do |k|
              d0 = 90.0 * k / steps
              d1 = 90.0 * (k + 1) / steps
              plan = [pivot, edge.call(d0)]
              plan << at.call(width, width) if d0 < 44.99 && d1 > 45.01
              plan << edge.call(d1)
              top = base + (level + k + 1) * r
              kind = type == 'winder' ? "Putar #{k + 1}" : 'Bordes'
              Standards.element("#{label} #{parts} #{kind}", :tangga, parent, spec['material'], spec['color']) { |ents| prism(ents, plan, top - r, top) }
            end
            note.call([at.call(0, 0), at.call(width, 0), at.call(width, width), at.call(0, width)])
            pos = [pivot[0] + dir[0] * width / 2.0, pivot[1] + dir[1] * width / 2.0]
            dir = inner
            level += steps
          else
            raise "Unknown stair segment #{type.inspect}. Use flight, winder or landing"
          end
        end

        summary = "Stairs '#{label}': #{risers} risers of #{format('%.4f', r)} m, #{level} treads in #{parts} parts, width #{format('%.2f', width)} m. " \
                  "The last riser lands at [#{format('%.3f', pos[0])}, #{format('%.3f', pos[1])}] on +#{format('%.3f', base + rise)} m, " \
                  "walking towards [#{dir[0].round}, #{dir[1].round}]. " \
                  "Footprint x #{format('%.3f', xs.min)}..#{format('%.3f', xs.max)}, y #{format('%.3f', ys.min)}..#{format('%.3f', ys.max)} m: " \
                  "the floor above must be open over it (leave it out of the slab outline)."
        summary += " WARNING: #{level} treads were drawn but #{risers} risers need #{risers - 1}; the top does not meet the floor above." if level != risers - 1
        r > 0.2 ? summary + " WARNING: risers above 0.20 m are steep." : summary + " Next: check_placement."
      end
    end

    # -------------------------------------------------------------- furniture

    WOOD = ['Furnitur - Kayu', [150, 110, 72]].freeze
    CLOTH = ['Furnitur - Kain Abu', [120, 132, 150]].freeze
    BEDDING = ['Furnitur - Kain Krem', [214, 208, 190]].freeze
    CHINA = ['Furnitur - Porselen', [248, 248, 246]].freeze
    CABINET = ['Furnitur - Kabinet Putih', [236, 234, 226]].freeze
    STEEL = ['Furnitur - Baja', [170, 174, 178]].freeze
    # type => [name, width, depth, height, material]. Width runs along local x,
    # the back of the piece is at +y (rotation 0 puts the back to the north).
    CATALOGUE = {
      'bed' => ['Kasur', 1.6, 2.0, 0.5, BEDDING], 'sofa' => ['Sofa', 2.0, 0.9, 0.8, CLOTH],
      'table' => ['Meja', 1.6, 0.9, 0.75, WOOD], 'chair' => ['Kursi', 0.45, 0.45, 0.9, WOOD],
      'desk' => ['Meja Kerja', 1.2, 0.6, 0.75, WOOD], 'cabinet' => ['Kabinet', 1.2, 0.6, 0.9, CABINET],
      'wardrobe' => ['Lemari', 1.2, 0.6, 2.0, WOOD], 'fridge' => ['Kulkas', 0.7, 0.7, 1.8, STEEL],
      'stove' => ['Kompor', 0.6, 0.6, 0.9, STEEL], 'toilet' => ['Kloset', 0.4, 0.7, 0.8, CHINA],
      'sink' => ['Wastafel', 0.6, 0.5, 0.85, CABINET], 'bathtub' => ['Bathtub', 0.75, 1.7, 0.55, CHINA],
      'shower' => ['Shower', 0.9, 0.9, 0.08, CHINA]
    }.freeze
    ALIASES = { 'kasur' => 'bed', 'meja' => 'table', 'kursi' => 'chair', 'meja kerja' => 'desk', 'kabinet' => 'cabinet',
                'lemari' => 'wardrobe', 'kulkas' => 'fridge', 'kompor' => 'stove', 'kloset' => 'toilet', 'wastafel' => 'sink' }.freeze

    def self.piece(ents, type, w, d, h)
      x = w / 2.0
      y = d / 2.0
      case type
      when 'bed'
        box(ents, -x, x, -y, y, 0, h)
        box(ents, -x - 0.02, x + 0.02, y, y + 0.05, 0, h + 0.5)
        before = ents.grep(Sketchup::Face)
        pw = w / 2.0 - 0.12
        [-1, 1].each do |k|
          cx = k * w / 4.0
          box(ents, cx - pw / 2.0, cx + pw / 2.0, y - 0.5, y - 0.1, h, h + 0.1)
        end
        paint(ents.grep(Sketchup::Face) - before, Standards.material(:furnitur, *CHINA))
      when 'sofa'
        box(ents, -x, x, -y, y, 0, 0.42)
        box(ents, -x, x, y - 0.2, y, 0.42, h)
        box(ents, -x, -x + 0.2, -y, y - 0.2, 0.42, 0.62)
        box(ents, x - 0.2, x, -y, y - 0.2, 0.42, 0.62)
      when 'table', 'desk'
        box(ents, -x, x, -y, y, h - 0.04, h)
        [[-x, -y], [x - 0.06, -y], [-x, y - 0.06], [x - 0.06, y - 0.06]].each { |lx, ly| box(ents, lx, lx + 0.06, ly, ly + 0.06, 0, h - 0.04) }
      when 'chair'
        box(ents, -x, x, -y, y, 0.41, 0.45)
        [[-x, -y], [x - 0.04, -y], [-x, y - 0.04], [x - 0.04, y - 0.04]].each { |lx, ly| box(ents, lx, lx + 0.04, ly, ly + 0.04, 0, 0.41) }
        box(ents, -x, x, y - 0.04, y, 0.45, h)
      when 'toilet'
        box(ents, -x, x, y - 0.2, y, 0, h)
        box(ents, -x + 0.02, x - 0.02, -y, y - 0.2, 0, 0.4)
      when 'bathtub'
        rim = 0.07
        box(ents, -x, x, -y, y, 0, 0.12)
        box(ents, -x, -x + rim, -y, y, 0.12, h)
        box(ents, x - rim, x, -y, y, 0.12, h)
        box(ents, -x + rim, x - rim, -y, -y + rim, 0.12, h)
        box(ents, -x + rim, x - rim, y - rim, y, 0.12, h)
      else
        box(ents, -x, x, -y, y, 0, h)
      end
    end

    def self.furniture(spec)
      items = spec['items'] || raise('place_furniture needs "items": [{"type": "bed", "at": [x, y]}, ...]')
      base = (spec['base_z'] || 0).to_f
      counts = Hash.new(0)
      placed = []

      operation('perabot') do
        parent = home(spec, spec['floor'])
        items.each do |item|
          type = item['type'].to_s.downcase
          type = ALIASES[type] || type
          row = CATALOGUE[type] || raise("Unknown furniture type #{item['type'].inspect}. Use one of: #{CATALOGUE.keys.join(', ')}")
          at = item['at'] || raise("#{type}: needs \"at\": [x, y], the middle of the piece, in metres")
          w, d, h = item['size'] || row[1..3]
          counts[type] += 1
          name = (item['name'] || "#{row[0]} #{counts[type]}").to_s
          parent.entities.grep(Sketchup::Group).select { |g| g.name == name }.each(&:erase!)
          material, rgb = item['material'] ? [item['material'], item['color']] : row[4]
          group = Standards.element(name, :furnitur, parent, material, rgb) { |ents| piece(ents, type, w.to_f, d.to_f, h.to_f) }
          z = (item['z'] || base).to_f
          group.transformation = Geom::Transformation.translation(Geom::Vector3d.new(at[0].to_f.m, at[1].to_f.m, z.m)) *
                                 Geom::Transformation.rotation(ORIGIN, Z_AXIS, (item['rotation'] || 0).to_f.degrees)
          placed << name
        end
        "#{placed.length} pieces placed in '#{parent.name}': #{placed.join(', ')}.\n" + Placement.report('building' => spec['building'])
      end
    end
  end

  def self.build_roof(spec)
    Detail.roof(spec)
  end

  def self.add_siding(spec = {})
    Detail.siding(spec)
  end

  def self.add_window_trim(spec = {})
    Detail.window_trim(spec)
  end

  def self.add_posts(spec)
    Detail.posts(spec)
  end

  def self.build_stairs(spec)
    Detail.stairs(spec)
  end

  def self.place_furniture(spec)
    Detail.furniture(spec)
  end


  def self.tag(kind)
    Standards.tag(kind)
  end

  def self.material(kind, name = nil, rgb = nil, opacity = nil)
    Standards.material(kind, name, rgb, opacity)
  end

  def self.element(name, kind, parent = nil, material_name = nil, rgb = nil, &block)
    Standards.element(name, kind, parent, material_name, rgb, &block)
  end

  def self.container(name)
    Standards.container(name)
  end

  def self.audit_model
    Standards.audit
  end

  class Server
    attr_reader :port

    def initialize
      @port = 9876
      @server = nil
      @running = false
      @timer_id = nil
      @clients = {}
    end

    def running?
      @running ? true : false
    end

    def log(msg)
      begin
        SKETCHUP_CONSOLE.write("MCP: #{msg}\n")
      rescue
        puts "MCP: #{msg}"
      end
      STDOUT.flush
    end

    def start
      return if @running
      
      begin
        log "Starting server on localhost:#{@port}..."
        
        @server = TCPServer.new('127.0.0.1', @port)
        log "Server created on port #{@port}"
        
        @running = true
        @clients ||= {}
        
        @timer_id = UI.start_timer(0.1, true) {
          begin
            if @running
              # Accept every pending connection without ever blocking the UI thread
              while IO.select([@server], nil, nil, 0)
                begin
                  client = @server.accept_nonblock
                  @clients[client] = ""
                  log "Client accepted (#{@clients.size} open)"
                rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
                  break
                end
              end

              # Service each open client. Connections are kept alive across ticks
              # because the python side treats this socket as persistent.
              @clients.keys.each do |client|
                begin
                  # Drain only what is already available; never wait for more
                  while IO.select([client], nil, nil, 0)
                    begin
                      chunk = client.read_nonblock(4096)
                    rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
                      break
                    end
                    raise EOFError if chunk.nil? || chunk.empty?
                    @clients[client] << chunk
                  end

                  # Handle every complete newline-terminated request in the buffer
                  while (idx = @clients[client].index("\n"))
                    line = @clients[client].slice!(0, idx + 1).strip
                    next if line.empty?

                    log "Raw data: #{line.inspect}"
                    original_id = nil
                    request = nil

                    begin
                      request = JSON.parse(line)
                      original_id = $1.to_i if line =~ /"id":\s*(\d+)/
                      if !request["id"] && original_id
                        request["id"] = original_id
                        log "Added missing ID: #{original_id}"
                      end

                      log "Processed request: #{request.inspect}"
                      response = handle_jsonrpc_request(request)
                      if response.nil?
                        log "No response required for method #{request["method"].inspect}"
                        next
                      end
                      response_json = response.to_json + "\n"

                      log "Sending response: #{response_json.strip}"
                      client.write(response_json)
                      client.flush
                      log "Response sent"
                    rescue JSON::ParserError => e
                      log "JSON parse error: #{e.message}"
                      client.write({
                        jsonrpc: "2.0",
                        error: { code: -32700, message: "Parse error" },
                        id: original_id
                      }.to_json + "\n")
                      client.flush
                    rescue StandardError => e
                      log "Request error: #{e.message}"
                      client.write({
                        jsonrpc: "2.0",
                        error: { code: -32603, message: e.message },
                        id: request ? request["id"] : original_id
                      }.to_json + "\n")
                      client.flush
                    end
                  end
                rescue EOFError, IOError, SystemCallError => e
                  # Every socket error ends this client, not just a clean close.
                  # On Windows a peer that gave up waiting shows as ECONNABORTED;
                  # left in the list it would raise on every tick and keep the
                  # clients after it from ever being served.
                  log "Client disconnected (#{e.class})"
                  @clients.delete(client)
                  begin
                    client.close
                  rescue StandardError
                  end
                end
              end
            end
          rescue StandardError => e
            log "Timer error: #{e.message}"
            log e.backtrace.join("\n")
          end
        }
        
        log "Server started and listening"

      rescue Errno::EADDRINUSE => e
        log "Port #{@port} is already in use (another SketchUp window is probably running the MCP server)."
        stop
      rescue StandardError => e
        log "Error: #{e.message}"
        log e.backtrace.join("\n")
        stop
      end
    end

    def stop
      log "Stopping server..."
      @running = false
      
      if @timer_id
        UI.stop_timer(@timer_id)
        @timer_id = nil
      end
      
      @clients.each_key { |c| begin; c.close; rescue StandardError; end }
      @clients.clear
      @server.close if @server
      @server = nil
      log "Server stopped"
    end

    private

    def handle_jsonrpc_request(request)
      log "Handling JSONRPC request: #{request.inspect}"
      
      # Handle direct command format (for backward compatibility)
      if request["command"]
        tool_request = {
          "method" => "tools/call",
          "params" => {
            "name" => request["command"],
            "arguments" => request["parameters"]
          },
          "jsonrpc" => request["jsonrpc"] || "2.0",
          "id" => request["id"]
        }
        log "Converting to tool request: #{tool_request.inspect}"
        return handle_tool_call(tool_request)
      end

      # Handle jsonrpc format
      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "ping"
        # The python client fires a ping on every call and never reads the
        # reply. Answering it leaves a stale response in the socket buffer
        # that is consumed as the answer to the NEXT request.
        nil
      when "resources/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            resources: list_resources,
            success: true
          },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            prompts: [],
            success: true
          },
          id: request["id"]
        }
      else
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32601, 
            message: "Method not found",
            data: { success: false }
          },
          id: request["id"]
        }
      end
    end

    def list_resources
      model = Sketchup.active_model
      return [] unless model
      
      model.entities.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
    end

    def handle_tool_call(request)
      log "Handling tool call: #{request.inspect}"
      tool_name = request["params"]["name"]
      args = request["params"]["arguments"]

      begin
        result = case tool_name
        when "create_component"
          create_component(args)
        when "delete_component"
          delete_component(args)
        when "transform_component"
          transform_component(args)
        when "get_selection"
          get_selection
        when "export", "export_scene"
          export_scene(args)
        when "set_material"
          set_material(args)
        when "boolean_operation"
          boolean_operation(args)
        when "chamfer_edges"
          chamfer_edges(args)
        when "fillet_edges"
          fillet_edges(args)
        when "create_mortise_tenon"
          create_mortise_tenon(args)
        when "create_dovetail"
          create_dovetail(args)
        when "create_finger_joint"
          create_finger_joint(args)
        when "build_floor_plan"
          build_floor_plan(args)
        when "verify_dimensions"
          verify_dimensions(args)
        when "add_plan_view"
          add_plan_view(args)
        when "check_placement"
          { success: true, result: Placement.report(args) }
        when "export_views"
          { success: true, result: Views.export(args) }
        when "build_roof"
          { success: true, result: Detail.roof(detail_spec(args)) }
        when "add_siding"
          { success: true, result: Detail.siding(detail_spec(args)) }
        when "add_window_trim"
          { success: true, result: Detail.window_trim(detail_spec(args)) }
        when "add_posts"
          { success: true, result: Detail.posts(detail_spec(args)) }
        when "build_stairs"
          { success: true, result: Detail.stairs(detail_spec(args)) }
        when "place_furniture"
          { success: true, result: Detail.furniture(detail_spec(args)) }
        when "eval_ruby"
          eval_ruby(args)
        else
          raise "Unknown tool: #{tool_name}"
        end

        log "Tool call result: #{result.inspect}"
        if result[:success]
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: {
              content: [{ type: "text", text: result[:result] || result[:path] || "Success" }],
              isError: false,
              success: true,
              resourceId: result[:id]
            },
            id: request["id"]
          }
          log "Sending success response: #{response.inspect}"
          response
        else
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            error: { 
              code: -32603, 
              message: "Operation failed",
              data: { success: false }
            },
            id: request["id"]
          }
          log "Sending error response: #{response.inspect}"
          response
        end
      rescue StandardError => e
        log "Tool call error: #{e.message}"
        response = {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32603, 
            message: e.message,
            data: { success: false }
          },
          id: request["id"]
        }
        log "Sending error response: #{response.inspect}"
        response
      end
    end

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      log "Got active model: #{model.inspect}"
      entities = model.active_entities
      log "Got active entities: #{entities.inspect}"
      
      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]
      
      case params["type"]
      when "cube"
        log "Creating cube at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          group = entities.add_group
          log "Created group: #{group.inspect}"
          
          face = group.entities.add_face(
            [pos[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
            [pos[0], pos[1] + dims[1], pos[2]]
          )
          log "Created face: #{face.inspect}"
          
          face.pushpull(dims[2])
          log "Pushed/pulled face by #{dims[2]}"
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error in create_component: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cylinder"
        log "Creating cylinder at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cylinder
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face
          face = group.entities.add_face(circle_points)
          
          # Extrude the face to create the cylinder
          face.pushpull(height)
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cylinder, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cylinder: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "sphere"
        log "Creating sphere at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the sphere
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]
          
          # Use SketchUp's built-in sphere method if available
          if Sketchup::Tools.respond_to?(:create_sphere)
            Sketchup::Tools.create_sphere(center, radius, 24, group.entities)
          else
            # Fallback implementation using polygons
            # Create a UV sphere with latitude and longitude segments
            segments = 16
            
            # Create points for the sphere
            points = []
            for lat_i in 0..segments
              lat = Math::PI * lat_i / segments
              for lon_i in 0..segments
                lon = 2 * Math::PI * lon_i / segments
                x = center[0] + radius * Math.sin(lat) * Math.cos(lon)
                y = center[1] + radius * Math.sin(lat) * Math.sin(lon)
                z = center[2] + radius * Math.cos(lat)
                points << [x, y, z]
              end
            end
            
            # Create faces for the sphere (simplified approach)
            for lat_i in 0...segments
              for lon_i in 0...segments
                i1 = lat_i * (segments + 1) + lon_i
                i2 = i1 + 1
                i3 = i1 + segments + 1
                i4 = i3 + 1
                
                # Create a quad face
                begin
                  group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
                rescue StandardError => e
                  # Skip faces that can't be created (may happen at poles)
                  log "Skipping face: #{e.message}"
                end
              end
            end
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created sphere, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating sphere: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cone"
        log "Creating cone at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cone
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          apex = [center[0], center[1], center[2] + height]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face for the base
          base = group.entities.add_face(circle_points)
          
          # Create the cone sides
          (0...num_segments).each do |i|
            j = (i + 1) % num_segments
            # Create a triangular face from two adjacent points on the circle to the apex
            group.entities.add_face(circle_points[i], circle_points[j], apex)
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cone, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cone: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      else
        raise "Unknown component type: #{params["type"]}"
      end
    end

    def delete_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        entity.erase!
        { success: true }
      else
        raise "Entity not found"
      end
    end

    def transform_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        # Handle position
        if params["position"]
          pos = params["position"]
          log "Transforming position to #{pos.inspect}"
          
          # Create a transformation to move the entity
          translation = Geom::Transformation.translation(Geom::Point3d.new(pos[0], pos[1], pos[2]))
          entity.transform!(translation)
        end
        
        # Handle rotation (in degrees)
        if params["rotation"]
          rot = params["rotation"]
          log "Rotating by #{rot.inspect} degrees"
          
          # Convert to radians
          x_rot = rot[0] * Math::PI / 180
          y_rot = rot[1] * Math::PI / 180
          z_rot = rot[2] * Math::PI / 180
          
          # Apply rotations
          if rot[0] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(1, 0, 0), x_rot)
            entity.transform!(rotation)
          end
          
          if rot[1] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 1, 0), y_rot)
            entity.transform!(rotation)
          end
          
          if rot[2] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 0, 1), z_rot)
            entity.transform!(rotation)
          end
        end
        
        # Handle scale
        if params["scale"]
          scale = params["scale"]
          log "Scaling by #{scale.inspect}"
          
          # Create a transformation to scale the entity
          center = entity.bounds.center
          scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
          entity.transform!(scaling)
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection
      
      log "Getting selection, count: #{selection.length}"
      
      selected_entities = selection.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
      
      { success: true, entities: selected_entities }
    end
    
    def export_scene(params)
      log "Exporting scene with params: #{params.inspect}"
      model = Sketchup.active_model
      
      format = params["format"] || "skp"
      
      begin
        # Create a temporary directory for exports
        temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
        FileUtils.mkdir_p(temp_dir) unless Dir.exist?(temp_dir)
        
        # Generate a unique filename
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "sketchup_export_#{timestamp}"
        
        case format.downcase
        when "skp"
          # Export as SketchUp file
          export_path = File.join(temp_dir, "#{filename}.skp")
          log "Exporting to SketchUp file: #{export_path}"
          model.save(export_path)
          
        when "obj"
          # Export as OBJ file
          export_path = File.join(temp_dir, "#{filename}.obj")
          log "Exporting to OBJ file: #{export_path}"
          
          # Check if OBJ exporter is available
          if Sketchup.require("sketchup.rb")
            options = {
              :triangulated_faces => true,
              :double_sided_faces => true,
              :edges => false,
              :texture_maps => true
            }
            model.export(export_path, options)
          else
            raise "OBJ exporter not available"
          end
          
        when "dae"
          # Export as COLLADA file
          export_path = File.join(temp_dir, "#{filename}.dae")
          log "Exporting to COLLADA file: #{export_path}"
          
          # Check if COLLADA exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :triangulated_faces => true }
            model.export(export_path, options)
          else
            raise "COLLADA exporter not available"
          end
          
        when "stl"
          # Export as STL file
          export_path = File.join(temp_dir, "#{filename}.stl")
          log "Exporting to STL file: #{export_path}"
          
          # Check if STL exporter is available
          if Sketchup.require("sketchup.rb")
            options = { :units => "model" }
            model.export(export_path, options)
          else
            raise "STL exporter not available"
          end
          
        when "png", "jpg", "jpeg"
          # Export as image
          ext = format.downcase == "jpg" ? "jpeg" : format.downcase
          export_path = File.join(temp_dir, "#{filename}.#{ext}")
          log "Exporting to image file: #{export_path}"
          
          # Get the current view
          view = model.active_view
          
          # Set up options for the export
          options = {
            :filename => export_path,
            :width => params["width"] || 1920,
            :height => params["height"] || 1080,
            :antialias => true,
            :transparent => (ext == "png")
          }
          
          # Export the image
          view.write_image(options)
          
        else
          raise "Unsupported export format: #{format}"
        end
        
        log "Export completed successfully to: #{export_path}"
        
        { 
          success: true, 
          path: export_path,
          format: format
        }
      rescue StandardError => e
        log "Error in export_scene: #{e.message}"
        log e.backtrace.join("\n")
        raise
      end
    end
    
    def set_material(params)
      log "Setting material with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        material_name = params["material"]
        log "Setting material to: #{material_name}"
        
        # Get or create the material
        material = model.materials[material_name]
        if !material
          # Create a new material if it doesn't exist
          material = model.materials.add(material_name)
          
          # Handle color specification
          case material_name.downcase
          when "red"
            material.color = Sketchup::Color.new(255, 0, 0)
          when "green"
            material.color = Sketchup::Color.new(0, 255, 0)
          when "blue"
            material.color = Sketchup::Color.new(0, 0, 255)
          when "yellow"
            material.color = Sketchup::Color.new(255, 255, 0)
          when "cyan", "turquoise"
            material.color = Sketchup::Color.new(0, 255, 255)
          when "magenta", "purple"
            material.color = Sketchup::Color.new(255, 0, 255)
          when "white"
            material.color = Sketchup::Color.new(255, 255, 255)
          when "black"
            material.color = Sketchup::Color.new(0, 0, 0)
          when "brown"
            material.color = Sketchup::Color.new(139, 69, 19)
          when "orange"
            material.color = Sketchup::Color.new(255, 165, 0)
          when "gray", "grey"
            material.color = Sketchup::Color.new(128, 128, 128)
          else
            # If it's a hex color code like "#FF0000"
            if material_name.start_with?("#") && material_name.length == 7
              begin
                r = material_name[1..2].to_i(16)
                g = material_name[3..4].to_i(16)
                b = material_name[5..6].to_i(16)
                material.color = Sketchup::Color.new(r, g, b)
              rescue
                # Default to a wood color if parsing fails
                material.color = Sketchup::Color.new(184, 134, 72)
              end
            else
              # Default to a wood color
              material.color = Sketchup::Color.new(184, 134, 72)
            end
          end
        end
        
        # Apply the material to the entity
        if entity.respond_to?(:material=)
          entity.material = material
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          # For groups and components, we need to apply to all faces
          entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          entities.grep(Sketchup::Face).each { |face| face.material = material }
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end
    
    def boolean_operation(params)
      log "Performing boolean operation with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get operation type
      operation_type = params["operation"]
      unless ["union", "difference", "intersection"].include?(operation_type)
        raise "Invalid boolean operation: #{operation_type}. Must be 'union', 'difference', or 'intersection'."
      end
      
      # Get target and tool entities
      target_id = params["target_id"].to_s.gsub('"', '')
      tool_id = params["tool_id"].to_s.gsub('"', '')
      
      log "Looking for target entity with ID: #{target_id}"
      target_entity = model.find_entity_by_id(target_id.to_i)
      
      log "Looking for tool entity with ID: #{tool_id}"
      tool_entity = model.find_entity_by_id(tool_id.to_i)
      
      unless target_entity && tool_entity
        missing = []
        missing << "target" unless target_entity
        missing << "tool" unless tool_entity
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (target_entity.is_a?(Sketchup::Group) || target_entity.is_a?(Sketchup::ComponentInstance)) &&
             (tool_entity.is_a?(Sketchup::Group) || tool_entity.is_a?(Sketchup::ComponentInstance))
        raise "Boolean operations require groups or component instances"
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Perform the boolean operation
      case operation_type
      when "union"
        log "Performing union operation"
        perform_union(target_entity, tool_entity, result_group)
      when "difference"
        log "Performing difference operation"
        perform_difference(target_entity, tool_entity, result_group)
      when "intersection"
        log "Performing intersection operation"
        perform_intersection(target_entity, tool_entity, result_group)
      end
      
      # Clean up original entities if requested
      if params["delete_originals"]
        target_entity.erase! if target_entity.valid?
        tool_entity.erase! if tool_entity.valid?
      end
      
      # Return the result
      { 
        success: true, 
        id: result_group.entityID
      }
    end
    
    def perform_union(target, tool, result_group)
      model = Sketchup.active_model
      
      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy
      
      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation
      
      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)
      
      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities
      
      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end
      
      # Copy all entities from tool to result
      tool_entities.each do |entity|
        entity.copy(result_group.entities)
      end
      
      # Clean up temporary copies
      target_copy.erase!
      tool_copy.erase!
      
      # Outer shell - this will merge overlapping geometry
      result_group.entities.outer_shell
    end
    
    def perform_difference(target, tool, result_group)
      model = Sketchup.active_model
      
      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy
      
      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation
      
      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)
      
      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities
      
      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end
      
      # Create a temporary group for the tool
      temp_tool_group = model.active_entities.add_group
      
      # Copy all entities from tool to temp group
      tool_entities.each do |entity|
        entity.copy(temp_tool_group.entities)
      end
      
      # Subtract the tool from the result
      result_group.entities.subtract(temp_tool_group.entities)
      
      # Clean up temporary copies and groups
      target_copy.erase!
      tool_copy.erase!
      temp_tool_group.erase!
    end
    
    def perform_intersection(target, tool, result_group)
      model = Sketchup.active_model
      
      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy
      
      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation
      
      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)
      
      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities
      
      # Create temporary groups for target and tool
      temp_target_group = model.active_entities.add_group
      temp_tool_group = model.active_entities.add_group
      
      # Copy all entities from target and tool to temp groups
      target_entities.each do |entity|
        entity.copy(temp_target_group.entities)
      end
      
      tool_entities.each do |entity|
        entity.copy(temp_tool_group.entities)
      end
      
      # Perform the intersection
      result_group.entities.intersect_with(temp_target_group.entities, temp_tool_group.entities)
      
      # Clean up temporary copies and groups
      target_copy.erase!
      tool_copy.erase!
      temp_target_group.erase!
      temp_tool_group.erase!
    end
    
    def chamfer_edges(params)
      log "Chamfering edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Chamfer operation requires a group or component instance"
      end
      
      # Get the distance parameter
      distance = params["distance"] || 0.5
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the chamfer operation
      begin
        # Create a transformation for the chamfer
        chamfer_transform = Geom::Transformation.scaling(1.0 - distance)
        
        # For each edge, create a chamfer
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Create a chamfer by creating a new face
          # This is a simplified approach - in a real implementation,
          # you would need to handle various edge cases
          new_points = []
          
          # For each vertex of the edge
          [edge.start, edge.end].each do |vertex|
            # Get all edges connected to this vertex
            connected_edges = vertex.edges - [edge]
            
            # For each connected edge
            connected_edges.each do |connected_edge|
              # Get the other vertex of the connected edge
              other_vertex = (connected_edge.vertices - [vertex])[0]
              
              # Calculate a point along the connected edge
              direction = other_vertex.position - vertex.position
              new_point = vertex.position.offset(direction, distance)
              
              new_points << new_point
            end
          end
          
          # Create a new face using the new points
          if new_points.length >= 3
            result_group.entities.add_face(new_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in chamfer_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def fillet_edges(params)
      log "Filleting edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Fillet operation requires a group or component instance"
      end
      
      # Get the radius parameter
      radius = params["radius"] || 0.5
      
      # Get the number of segments for the fillet
      segments = params["segments"] || 8
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the fillet operation
      begin
        # For each edge, create a fillet
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Calculate the edge vector
          edge_vector = end_point - start_point
          edge_length = edge_vector.length
          
          # Create points for the fillet curve
          fillet_points = []
          
          # Create a series of points along a circular arc
          (0..segments).each do |i|
            angle = Math::PI * i / segments
            
            # Calculate the point on the arc
            x = midpoint.x + radius * Math.cos(angle)
            y = midpoint.y + radius * Math.sin(angle)
            z = midpoint.z
            
            fillet_points << Geom::Point3d.new(x, y, z)
          end
          
          # Create edges connecting the fillet points
          (0...fillet_points.length - 1).each do |i|
            result_group.entities.add_line(fillet_points[i], fillet_points[i+1])
          end
          
          # Create a face from the fillet points
          if fillet_points.length >= 3
            result_group.entities.add_face(fillet_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in fillet_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def create_mortise_tenon(params)
      log "Creating mortise and tenon joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the mortise and tenon board IDs
      mortise_id = params["mortise_id"].to_s.gsub('"', '')
      tenon_id = params["tenon_id"].to_s.gsub('"', '')
      
      log "Looking for mortise board with ID: #{mortise_id}"
      mortise_board = model.find_entity_by_id(mortise_id.to_i)
      
      log "Looking for tenon board with ID: #{tenon_id}"
      tenon_board = model.find_entity_by_id(tenon_id.to_i)
      
      unless mortise_board && tenon_board
        missing = []
        missing << "mortise board" unless mortise_board
        missing << "tenon board" unless tenon_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (mortise_board.is_a?(Sketchup::Group) || mortise_board.is_a?(Sketchup::ComponentInstance)) &&
             (tenon_board.is_a?(Sketchup::Group) || tenon_board.is_a?(Sketchup::ComponentInstance))
        raise "Mortise and tenon operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Get the bounds of both boards
      mortise_bounds = mortise_board.bounds
      tenon_bounds = tenon_board.bounds
      
      # Determine the face to place the joint on based on the relative positions of the boards
      mortise_center = mortise_bounds.center
      tenon_center = tenon_bounds.center
      
      # Calculate the direction vector from mortise to tenon
      direction_vector = tenon_center - mortise_center
      
      # Determine which face of the mortise board is closest to the tenon board
      mortise_face_direction = determine_closest_face(direction_vector)
      
      # Create the mortise (hole) in the mortise board
      mortise_result = create_mortise(
        mortise_board, 
        width, 
        height, 
        depth, 
        mortise_face_direction,
        mortise_bounds,
        offset_x, 
        offset_y, 
        offset_z
      )
      
      # Determine which face of the tenon board is closest to the mortise board
      tenon_face_direction = determine_closest_face(direction_vector.reverse)
      
      # Create the tenon (projection) on the tenon board
      tenon_result = create_tenon(
        tenon_board, 
        width, 
        height, 
        depth, 
        tenon_face_direction,
        tenon_bounds,
        offset_x, 
        offset_y, 
        offset_z
      )
      
      # Return the result
      { 
        success: true, 
        mortise_id: mortise_result[:id],
        tenon_id: tenon_result[:id]
      }
    end
    
    def determine_closest_face(direction_vector)
      # Normalize the direction vector
      direction_vector.normalize!
      
      # Determine which axis has the largest component
      x_abs = direction_vector.x.abs
      y_abs = direction_vector.y.abs
      z_abs = direction_vector.z.abs
      
      if x_abs >= y_abs && x_abs >= z_abs
        # X-axis is dominant
        return direction_vector.x > 0 ? :east : :west
      elsif y_abs >= x_abs && y_abs >= z_abs
        # Y-axis is dominant
        return direction_vector.y > 0 ? :north : :south
      else
        # Z-axis is dominant
        return direction_vector.z > 0 ? :top : :bottom
      end
    end
    
    def create_mortise(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Calculate the position of the mortise based on the face direction
      mortise_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      
      log "Creating mortise at position: #{mortise_position.inspect} with dimensions: #{[width, height, depth].inspect}"
      
      # Create a box for the mortise
      mortise_group = entities.add_group
      
      # Create the mortise box with the correct orientation
      case face_direction
      when :east, :west
        # Mortise on east or west face (YZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :east ? -depth : depth)
      when :north, :south
        # Mortise on north or south face (XZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :north ? -depth : depth)
      when :top, :bottom
        # Mortise on top or bottom face (XY plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1] + height, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + height, mortise_position[2]]
        )
        mortise_face.pushpull(face_direction == :top ? -depth : depth)
      end
      
      # Subtract the mortise from the board
      entities.subtract(mortise_group.entities)
      
      # Clean up the temporary group
      mortise_group.erase!
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_tenon(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Calculate the position of the tenon based on the face direction
      tenon_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      
      log "Creating tenon at position: #{tenon_position.inspect} with dimensions: #{[width, height, depth].inspect}"
      
      # Create a box for the tenon
      tenon_group = model.active_entities.add_group
      
      # Create the tenon box with the correct orientation
      case face_direction
      when :east, :west
        # Tenon on east or west face (YZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :east ? depth : -depth)
      when :north, :south
        # Tenon on north or south face (XZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :north ? depth : -depth)
      when :top, :bottom
        # Tenon on top or bottom face (XY plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1] + height, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + height, tenon_position[2]]
        )
        tenon_face.pushpull(face_direction == :top ? depth : -depth)
      end
      
      # Get the transformation of the board
      board_transform = board.transformation
      
      # Apply the inverse transformation to the tenon group
      tenon_group.transform!(board_transform.inverse)
      
      # Union the tenon with the board
      board_entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      board_entities.add_instance(tenon_group.entities.parent, Geom::Transformation.new)
      
      # Clean up the temporary group
      tenon_group.erase!
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      # Calculate the position on the specified face with offsets
      case face_direction
      when :east
        # Position on the east face (max X)
        [
          bounds.max.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :west
        # Position on the west face (min X)
        [
          bounds.min.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :north
        # Position on the north face (max Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.max.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :south
        # Position on the south face (min Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.min.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :top
        # Position on the top face (max Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.max.z
        ]
      when :bottom
        # Position on the bottom face (min Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.min.z
        ]
      end
    end
    
    def create_dovetail(params)
      log "Creating dovetail joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the tail and pin board IDs
      tail_id = params["tail_id"].to_s.gsub('"', '')
      pin_id = params["pin_id"].to_s.gsub('"', '')
      
      log "Looking for tail board with ID: #{tail_id}"
      tail_board = model.find_entity_by_id(tail_id.to_i)
      
      log "Looking for pin board with ID: #{pin_id}"
      pin_board = model.find_entity_by_id(pin_id.to_i)
      
      unless tail_board && pin_board
        missing = []
        missing << "tail board" unless tail_board
        missing << "pin board" unless pin_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (tail_board.is_a?(Sketchup::Group) || tail_board.is_a?(Sketchup::ComponentInstance)) &&
             (pin_board.is_a?(Sketchup::Group) || pin_board.is_a?(Sketchup::ComponentInstance))
        raise "Dovetail operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      angle = params["angle"] || 15.0  # Dovetail angle in degrees
      num_tails = params["num_tails"] || 3
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the tails on the tail board
      tail_result = create_tails(tail_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      
      # Create the pins on the pin board
      pin_result = create_pins(pin_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      
      # Return the result
      { 
        success: true, 
        tail_id: tail_result[:id],
        pin_id: pin_result[:id]
      }
    end
    
    def create_tails(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)
      
      # Create a group for the tails
      tails_group = entities.add_group
      
      # Create each tail
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)
        
        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)
        
        # Create the tail shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]
        
        # Create the tail face
        tail_face = tails_group.entities.add_face(tail_points)
        
        # Extrude the tail
        tail_face.pushpull(height)
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_pins(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)
      
      # Create a group for the pins
      pins_group = entities.add_group
      
      # Create a box for the entire pin area
      pin_area_face = pins_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )
      
      # Extrude the pin area
      pin_area_face.pushpull(depth)
      
      # Create each tail cutout
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)
        
        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)
        
        # Create a group for the tail cutout
        tail_cutout_group = entities.add_group
        
        # Create the tail cutout shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]
        
        # Create the tail cutout face
        tail_face = tail_cutout_group.entities.add_face(tail_points)
        
        # Extrude the tail cutout
        tail_face.pushpull(height)
        
        # Subtract the tail cutout from the pin area
        pins_group.entities.subtract(tail_cutout_group.entities)
        
        # Clean up the temporary group
        tail_cutout_group.erase!
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_finger_joint(params)
      log "Creating finger joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the two board IDs
      board1_id = params["board1_id"].to_s.gsub('"', '')
      board2_id = params["board2_id"].to_s.gsub('"', '')
      
      log "Looking for board 1 with ID: #{board1_id}"
      board1 = model.find_entity_by_id(board1_id.to_i)
      
      log "Looking for board 2 with ID: #{board2_id}"
      board2 = model.find_entity_by_id(board2_id.to_i)
      
      unless board1 && board2
        missing = []
        missing << "board 1" unless board1
        missing << "board 2" unless board2
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (board1.is_a?(Sketchup::Group) || board1.is_a?(Sketchup::ComponentInstance)) &&
             (board2.is_a?(Sketchup::Group) || board2.is_a?(Sketchup::ComponentInstance))
        raise "Finger joint operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      num_fingers = params["num_fingers"] || 5
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the fingers on board 1
      board1_result = create_board1_fingers(board1, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      
      # Create the matching slots on board 2
      board2_result = create_board2_slots(board2, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      
      # Return the result
      { 
        success: true, 
        board1_id: board1_result[:id],
        board2_id: board2_result[:id]
      }
    end
    
    def create_board1_fingers(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each finger
      finger_width = width / num_fingers
      
      # Create a group for the fingers
      fingers_group = entities.add_group
      
      # Create a base rectangle for the joint area
      base_face = fingers_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )
      
      # Create cutouts for the spaces between fingers
      (num_fingers / 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i + 1)
        
        # Create a group for the cutout
        cutout_group = entities.add_group
        
        # Create the cutout shape
        cutout_face = cutout_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )
        
        # Extrude the cutout
        cutout_face.pushpull(depth)
        
        # Subtract the cutout from the fingers
        fingers_group.entities.subtract(cutout_group.entities)
        
        # Clean up the temporary group
        cutout_group.erase!
      end
      
      # Extrude the fingers
      base_face.pushpull(depth)
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_board2_slots(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each finger
      finger_width = width / num_fingers
      
      # Create a group for the slots
      slots_group = entities.add_group
      
      # Create cutouts for the fingers from board 1
      (num_fingers / 2 + num_fingers % 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i)
        
        # Create a group for the cutout
        cutout_group = entities.add_group
        
        # Create the cutout shape
        cutout_face = cutout_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )
        
        # Extrude the cutout
        cutout_face.pushpull(depth)
        
        # Subtract the cutout from the board
        entities.subtract(cutout_group.entities)
        
        # Clean up the temporary group
        cutout_group.erase!
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    # Build walls (with door and window openings), simple door leaves and window
    # panes, and a floor slab from a plan described in METRES. The spec format
    # is documented in docs/MODELING.md; tags and materials follow
    # docs/STANDARDS.md.
    #
    # Each wall is drawn as its elevation (length x height, with the openings
    # already cut out of the outline) and then extruded by its thickness, so no
    # boolean/solid tools are needed and it works in every SketchUp edition.
    #
    # A wall's from/to line is its centreline ("ref": "center"), its left face
    # ("left") or its right face ("right"), left and right as seen walking from
    # `from` to `to`. Wall ends are lengthened or trimmed automatically where
    # walls meet, so corners close and walls never overlap.
    def build_floor_plan(params)
      spec = params["spec"] || params
      spec = JSON.parse(spec) if spec.is_a?(String)
      model = Sketchup.active_model
      raise "No model is open in SketchUp" unless model

      wall_specs = spec["walls"] || []
      raise "spec.walls is empty" if wall_specs.empty?

      default_h = (spec["wall_height"] || 3.0).to_f
      default_t = (spec["wall_thickness"] || 0.15).to_f
      default_ref = (spec["wall_ref"] || "center").to_s
      base_z = (spec["base_z"] || 0).to_f
      name = (spec["name"] || "Denah").to_s
      openings = spec["openings"] || []
      infill = !(spec.key?("infill") && !spec["infill"])
      warnings = []
      wall_count = 0
      door_count = 0
      window_count = 0
      has_slab = false

      # --- pass 1: wall geometry in plan, all in metres -----------------------
      walls = []
      wall_specs.each_with_index do |w, i|
        id = (w["id"] || "W#{i + 1}").to_s
        a = [w["from"][0].to_f, w["from"][1].to_f]
        b = [w["to"][0].to_f, w["to"][1].to_f]
        t = (w["thickness"] || default_t).to_f
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        len = Math.sqrt(dx * dx + dy * dy)
        if len < 0.01
          warnings << "#{id}: zero length, skipped"
          next
        end
        ref = (w["ref"] || default_ref).to_s
        # Body extent across the wall, measured along its left normal.
        side = case ref
               when "center", "centre" then [-t / 2.0, t / 2.0]
               when "left" then [-t, 0.0]
               when "right" then [0.0, t]
               else raise "#{id}: ref must be \"center\", \"left\" or \"right\", got #{ref.inspect}"
               end
        dir = [dx / len, dy / len]
        walls << {
          index: walls.length, id: id, a: a, b: b, t: t, len: len, spec: w,
          h: (w["height"] || default_h).to_f,
          dir: dir, nrm: [-dir[1], dir[0]], side: side
        }
      end
      raise "spec.walls has no usable wall" if walls.empty?

      # How far one end of a wall must be lengthened (+) or trimmed (-) to meet
      # the walls it touches: up to the near face of a wall it runs into (T), and
      # at a corner (L) one wall takes the corner while the other stops short.
      join = lambda do |wall, at_start|
        p = at_start ? wall[:a] : wall[:b]
        u = at_start ? [-wall[:dir][0], -wall[:dir][1]] : wall[:dir]
        tee = nil
        corner = nil
        walls.each do |other|
          next if other.equal?(wall)
          rel = [p[0] - other[:a][0], p[1] - other[:a][1]]
          along = rel[0] * other[:dir][0] + rel[1] * other[:dir][1]
          across = rel[0] * other[:nrm][0] + rel[1] * other[:nrm][1]
          next if across.abs > 0.002 || along < -0.002 || along > other[:len] + 0.002
          c = other[:nrm][0] * u[0] + other[:nrm][1] * u[1]
          next if c.abs < 0.2 # (nearly) parallel: a continuation, not a junction
          reach = other[:side].map { |y| y / c }
          if along < 0.002 || along > other[:len] - 0.002
            corner ||= wall[:index] < other[:index] ? reach.max : reach.min
          else
            tee ||= reach.min
          end
        end
        tee || corner || 0.0
      end

      walls.each do |wall|
        e = wall[:spec]["extend"]
        wall[:ext] = if e == false
                       [0.0, 0.0]
                     elsif e.is_a?(Numeric)
                       [e.to_f, e.to_f]
                     elsif e.is_a?(Array)
                       [e[0].to_f, e[1].to_f]
                     else
                       [join.call(wall, true), join.call(wall, false)]
                     end
      end

      # Extrude a rectangle of the wall elevation into a thin panel centred on yc.
      panel = lambda do |ents, x0, x1, z0, z1, yc, thickness|
        y = (yc - thickness / 2.0).m
        face = ents.add_face(
          Geom::Point3d.new(x0.m, y, z0.m), Geom::Point3d.new(x1.m, y, z0.m),
          Geom::Point3d.new(x1.m, y, z1.m), Geom::Point3d.new(x0.m, y, z1.m)
        )
        face.pushpull(face.normal.y > 0 ? thickness.m : -thickness.m)
      end

      # --- pass 2: geometry ---------------------------------------------------
      # Extrude a frame seen in elevation: the rectangle x0..x1 by z0..z1 with a
      # border `inset` wide. open_bottom leaves the bottom side out (door frames).
      ring = lambda do |ents, x0, x1, z0, z1, inset, yc, depth, open_bottom|
        y = (yc - depth / 2.0).m
        pt = lambda { |x, z| Geom::Point3d.new(x.m, y, z.m) }
        if open_bottom
          ents.add_face(pt.call(x0, z0), pt.call(x0 + inset, z0), pt.call(x0 + inset, z1 - inset),
                        pt.call(x1 - inset, z1 - inset), pt.call(x1 - inset, z0), pt.call(x1, z0),
                        pt.call(x1, z1), pt.call(x0, z1))
        else
          ents.add_face(pt.call(x0, z0), pt.call(x1, z0), pt.call(x1, z1), pt.call(x0, z1))
          hole = ents.add_face(pt.call(x0 + inset, z0 + inset), pt.call(x1 - inset, z0 + inset),
                               pt.call(x1 - inset, z1 - inset), pt.call(x0 + inset, z1 - inset))
          hole.erase! if hole
        end
        face = ents.grep(Sketchup::Face).max_by { |f| f.area }
        face.pushpull(face.normal.y > 0 ? depth.m : -depth.m)
      end

      # Panelled door: two sunk panels on each side of a leaf that spans
      # x0..x1 by 0..top and is `thickness` thick around yc. Too small a leaf
      # is left flush.
      recess = lambda do |ents, x0, x1, top, yc, thickness|
        stile = 0.10
        next if x1 - x0 < 2 * stile + 0.15 || top < 1.5
        fields = [[0.20, 0.90], [1.05, top - stile]]
        [yc - thickness / 2.0, yc + thickness / 2.0].each do |y|
          fields.each do |z0, z1|
            next if z1 - z0 < 0.15
            pts = [[x0 + stile, z0], [x1 - stile, z0], [x1 - stile, z1], [x0 + stile, z1]]
            face = ents.add_face(pts.map { |x, z| Geom::Point3d.new(x.m, y.m, z.m) })
            next unless face
            outward = face.normal.y * (y - yc) > 0
            face.pushpull(outward ? -0.008.m : 0.008.m)
          end
        end
      end

      previous_layer = model.active_layer
      model.start_operation("MCP: #{name}", true)
      begin
        # Raw geometry must be Untagged whatever tag the user has active.
        model.active_layer = model.layers[0]
        building = spec["building"].to_s
        target = building.empty? ? model.active_entities : Standards.container(building).entities
        root = target.add_group
        root.name = name
        known_ids = walls.map { |w| w[:id] }

        walls.each do |wall|
          id = wall[:id]
          t = wall[:t]
          h = wall[:h]
          len = wall[:len]
          x_min = -wall[:ext][0]
          x_max = len + wall[:ext][1]
          if x_max - x_min < 0.02
            warnings << "#{id}: nothing left after trimming at the junctions, skipped"
            next
          end
          y_near, y_far = wall[:side]
          y_mid = (y_near + y_far) / 2.0

          doors = []
          windows = []
          openings.each do |o|
            next unless o["wall"].to_s == id
            x0 = o["offset"].to_f
            x1 = x0 + o["width"].to_f
            sill = (o["sill"] || 0).to_f
            top = sill + o["height"].to_f
            label = "#{o["type"] || "opening"} on #{id} at #{x0}"
            if o["width"].to_f <= 0 || o["height"].to_f <= 0
              warnings << "#{label}: width/height must be > 0, skipped"
            elsif x0 < x_min + 0.02 || x1 > x_max - 0.02
              warnings << "#{label}: does not fit in the wall (it runs from #{x_min.round(3)} to #{x_max.round(3)} m measured from its `from` point), skipped"
            elsif top > h - 0.02
              warnings << "#{label}: top (#{top} m) reaches the wall height (#{h} m), skipped"
            elsif sill <= 0.001
              doors << [x0, x1, top, o]
            else
              windows << [x0, x1, sill, top, o]
            end
          end
          doors.sort_by! { |d| d[0] }
          kept = []
          doors.each do |d|
            if kept.any? && d[0] < kept.last[1] + 0.02
              warnings << "door on #{id} at #{d[0]}: overlaps the previous door, skipped"
            else
              kept << d
            end
          end
          doors = kept

          placement = Geom::Transformation.new(Geom::Point3d.new(wall[:a][0].m, wall[:a][1].m, base_z.m)) *
                      Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math.atan2(wall[:dir][1], wall[:dir][0]))

          cut_windows = []
          group = Standards.element("Dinding #{id}", :dinding, root, wall[:spec]["material"]) do |ents|
            y = y_near.m
            pt = lambda { |x, z| Geom::Point3d.new(x.m, y, z.m) }
            outline = [pt.call(x_min, 0)]
            doors.each do |x0, x1, top, _o|
              outline << pt.call(x0, 0) << pt.call(x0, top) << pt.call(x1, top) << pt.call(x1, 0)
            end
            outline << pt.call(x_max, 0) << pt.call(x_max, h) << pt.call(x_min, h)
            ents.add_face(outline)

            windows.each do |x0, x1, sill, top, wo|
              hole = ents.add_face(pt.call(x0, sill), pt.call(x1, sill), pt.call(x1, top), pt.call(x0, top))
              if hole
                hole.erase!
                cut_windows << [x0, x1, sill, top, wo]
              else
                warnings << "window on #{id} at #{x0}: could not be cut"
              end
            end

            face = ents.grep(Sketchup::Face).max_by { |f| f.area }
            face.pushpull(face.normal.y > 0 ? t.m : -t.m)
          end
          group.transform!(placement)
          wall_count += 1

          # Frame (kusen) size for one opening, or nil when it gets none: switched
          # off, or the opening is too small to leave a usable clear opening.
          frame_for = lambda do |o, width, height|
            return nil if o.key?("frame") && !o["frame"]
            return nil if spec.key?("frames") && !spec["frames"]
            fw = (o["frame_width"] || spec["frame_width"] || 0.06).to_f
            fd = (o["frame_depth"] || spec["frame_depth"] || [0.12, t].min).to_f
            return nil if width - 2 * fw < 0.15 || height - 2 * fw < 0.15
            [fw, fd]
          end
          wood = [140, 95, 60]

          doors.each_with_index do |(x0, x1, top, o), n|
            door_count += 1
            next unless infill
            unit = root.entities.add_group
            unit.name = "Pintu #{id}-#{n + 1}"

            frame = frame_for.call(o, x1 - x0, top)
            if frame
              fw, fd = frame
              Standards.element("Kusen", :pintu, unit) { |ents| ring.call(ents, x0, x1, 0, top, fw, y_mid, fd, true) }
              lx0 = x0 + fw
              lx1 = x1 - fw
              leaf_top = top - fw
              face_left = y_mid + fd / 2.0
              face_right = y_mid - fd / 2.0
              leaf_t = 0.035
            else
              lx0 = x0
              lx1 = x1
              leaf_top = top
              face_left = y_far
              face_right = y_near
              leaf_t = 0.04
            end
            width = lx1 - lx0
            panelled = (o["style"] || spec["door_style"] || "panel").to_s == "panel"

            hinge = o["hinge"].to_s
            swing = o["swing"].to_s
            if !hinge.empty? || !swing.empty?
              hinge = "start" if hinge.empty?
              swing = "left" if swing.empty?
              unless %w[start end].include?(hinge) && %w[left right].include?(swing)
                warnings << "door on #{id} at #{x0}: hinge must be start/end and swing left/right; drawn closed"
                hinge = swing = ""
              end
            end

            if hinge.empty?
              # No swing given: a closed leaf in the middle of the wall.
              Standards.element("Daun", :pintu, unit) do |ents|
                panel.call(ents, lx0, lx1, 0, leaf_top, y_mid, leaf_t)
                recess.call(ents, lx0, lx1, leaf_top, y_mid, leaf_t) if panelled
              end
            else
              # The leaf is hinged on the jamb nearer `from` (start) or `to` (end),
              # flush with the frame face of the side it opens to, and drawn open.
              at_start = hinge == "start"
              to_left = swing == "left"
              open = (o["open"] || 90).to_f
              closed_angle = at_start ? 0.0 : 180.0
              turn = at_start == to_left ? open : -open
              pivot = Geom::Transformation.new(Geom::Point3d.new((at_start ? lx0 : lx1).m, (to_left ? face_left : face_right).m, 0))
              yc = at_start == to_left ? -leaf_t / 2.0 : leaf_t / 2.0
              leaf = Standards.element("Daun", :pintu, unit) do |ents|
                panel.call(ents, 0, width, 0, leaf_top, yc, leaf_t)
                recess.call(ents, 0, width, leaf_top, yc, leaf_t) if panelled
              end
              leaf.transform!(pivot * Geom::Transformation.rotation(ORIGIN, Z_AXIS, (closed_angle + turn).degrees))
              # Swing arc on the floor, the way a plan shows a door.
              angles = [closed_angle, closed_angle + turn].sort.map(&:degrees)
              arc = Standards.element("Ayun", :pintu, unit) do |ents|
                ents.add_arc(Geom::Point3d.new(0, 0, 0.005.m), X_AXIS, Z_AXIS, width.m, angles[0], angles[1], 16)
              end
              arc.transform!(pivot)
            end
            unit.transform!(placement)
          end

          cut_windows.each_with_index do |(x0, x1, sill, top, o), n|
            window_count += 1
            next unless infill
            unit = root.entities.add_group
            unit.name = "Jendela #{id}-#{n + 1}"

            frame = frame_for.call(o, x1 - x0, top - sill)
            if frame.nil?
              Standards.element("Kaca", :jendela, unit) { |ents| panel.call(ents, x0, x1, sill, top, y_mid, 0.01) }
            else
              fw, fd = frame
              Standards.element("Kusen", :jendela, unit, "Jendela - Kayu", wood) { |ents| ring.call(ents, x0, x1, sill, top, fw, y_mid, fd, false) }
              cx0 = x0 + fw
              cx1 = x1 - fw
              cz0 = sill + fw
              cz1 = top - fw
              clear = cx1 - cx0
              leaves = o["leaves"] ? o["leaves"].to_i : (clear <= 0.75 ? 1 : (clear <= 1.5 ? 2 : 3))
              if o["fixed"] || leaves <= 0
                # Fixed light: the glass sits straight in the frame.
                Standards.element("Kaca", :jendela, unit) { |ents| panel.call(ents, cx0, cx1, cz0, cz1, y_mid, 0.005) }
              else
                part = clear / leaves
                leaves.times do |i|
                  sx0 = cx0 + i * part
                  sx1 = sx0 + part
                  # Sash rail width, kept in proportion on small windows.
                  sw = [0.07, part / 4.0, (cz1 - cz0) / 4.0].min
                  suffix = leaves > 1 ? " #{i + 1}" : ""
                  Standards.element("Daun#{suffix}", :jendela, unit, "Jendela - Kayu", wood) { |ents| ring.call(ents, sx0, sx1, cz0, cz1, sw, y_mid, 0.03, false) }
                  Standards.element("Kaca#{suffix}", :jendela, unit) { |ents| panel.call(ents, sx0 + sw, sx1 - sw, cz0 + sw, cz1 - sw, y_mid, 0.005) }
                end
              end
            end
            unit.transform!(placement)
          end
        end

        openings.each do |o|
          warnings << "opening refers to unknown wall #{o["wall"].inspect}" unless known_ids.include?(o["wall"].to_s)
        end

        slab = spec["slab"]
        has_slab = slab && slab["outline"] && slab["outline"].length >= 3 ? true : false
        if has_slab
          thickness = (slab["thickness"] || 0.12).to_f
          Standards.element("Lantai", :lantai, root, slab["material"]) do |ents|
            points = slab["outline"].map { |p| Geom::Point3d.new(p[0].to_f.m, p[1].to_f.m, base_z.m) }
            face = ents.add_face(points)
            # A face on the ground plane is created facing down; make it face up
            # so the slab's top sits at base_z and its body goes below it.
            face.reverse! if face.normal.z < 0
            face.pushpull(-thickness.m)
          end
        end

        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      ensure
        model.active_layer = previous_layer
      end

      model.active_view.zoom_extents
      bb = root.bounds
      size = [bb.width, bb.height, bb.depth].map { |v| v.to_m.round(3) }
      summary = "Built '#{name}': #{wall_count} walls, #{door_count} doors, #{window_count} windows" \
                "#{has_slab ? ", 1 slab" : ""}. Size #{size[0]} x #{size[1]} x #{size[2]} m (x, y, z). " \
                "Group entityID #{root.entityID}. Next: verify_dimensions against the plan, " \
                "then SU_MCP.audit_model after adding anything else."
      summary += " Warnings: " + warnings.join("; ") unless warnings.empty?
      { success: true, id: root.entityID, result: summary }
    end

    def detail_spec(params)
      spec = (params && params["spec"]) || params || {}
      spec.is_a?(String) ? JSON.parse(spec) : spec
    end

    # Dimensioned top-view scene of the built plan.
    def add_plan_view(params)
      spec = params["spec"] || params
      spec = JSON.parse(spec) if spec.is_a?(String)
      { success: true, result: Plan.build(spec) }
    end

    # Measure the model and compare with the dimensions on the plan.
    def verify_dimensions(params)
      { success: true, result: Verify.report(params["checks"] || [], params["tolerance"]) }
    end

    def eval_ruby(params)
      log "Evaluating Ruby code with length: #{params['code'].length}"
      
      begin
        # Create a safe binding for evaluation
        binding = TOPLEVEL_BINDING.dup
        
        # Evaluate the Ruby code
        log "Starting code evaluation..."
        result = eval(params["code"], binding)
        log "Code evaluation completed with result: #{result.inspect}"
        
        # Return success with the result as a string
        { 
          success: true,
          result: result.to_s
        }
      rescue StandardError => e
        log "Error in eval_ruby: #{e.message}"
        log e.backtrace.join("\n")
        raise "Ruby evaluation error: #{e.message}"
      end
    end
  end

  unless file_loaded?(__FILE__)
    @server = Server.new
    
    menu = UI.menu("Plugins").add_submenu("MCP Server")
    menu.add_item("Start Server") { @server.start }
    menu.add_item("Stop Server") { @server.stop }
    menu.add_item("Status") {
      state = @server.running? ? "RUNNING on 127.0.0.1:#{@server.port}" : "STOPPED"
      UI.messagebox("SketchUp MCP server: #{state}\nAuto-start on launch: #{SU_MCP.autostart? ? 'on' : 'off'}")
    }
    autostart_item = menu.add_item("Auto-start on Launch") {
      SU_MCP.autostart = !SU_MCP.autostart?
    }
    menu.set_validation_proc(autostart_item) {
      SU_MCP.autostart? ? MF_CHECKED : MF_UNCHECKED
    }

    # Start listening as soon as SketchUp is up, so nobody has to remember
    # the menu click. Deferred with a timer so it never delays startup.
    UI.start_timer(1, false) { @server.start } if SU_MCP.autostart?

    file_loaded(__FILE__)
  end
end 