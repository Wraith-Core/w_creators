-- The single catalogue copy supplied by w_lib, shared by creator, stores and validation.
local catalogue
function GetLibraryPedComponentList()
    if not catalogue then
        local data=w.component.getFullPedComponentList()
        assert(type(data)=='table' and data.male and data.female,'w_lib component catalogue unavailable')
        catalogue=data
    end
    return catalogue
end
